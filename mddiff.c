//
// maildir diff (mddiff) computes the delta from an old status of a maildir
// (previously recorded in a support file) and the current status, generating
// a set of commands (a diff) that a third party software can apply to
// synchronize a (remote) copy of the maildir.
//
// Absolutely no warranties, released under GNU GPL version 3 or at your 
// option any later version.
//
// Copyright 2008 Enrico Tassi <tassi@cs.unibo.it>

#define _BSD_SOURCE
#define _GNU_SOURCE
#include <dirent.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/types.h>
#include <gcrypt.h>
#include <limits.h>
#include <errno.h>
#include <string.h>
#include <fcntl.h>
#include <getopt.h>
#include <glib.h>

#define SHA_DIGEST_LENGTH 20

#define __tostring(x) #x 
#define tostring(x) __tostring(x)

#define ERROR(cause, msg...) \
	fprintf(stderr, "error [" tostring(cause) "]: " msg)
#define VERBOSE(cause,msg...) \
	if (verbose) fprintf(stderr,"debug [" tostring(cause) "]: " msg)
#define VERBOSE_NOH(msg...) \
	if (verbose) fprintf(stderr,msg)

// default numbers for static memory allocation
#define DEFAULT_FILENAME_LEN 100
#define DEFAULT_MAIL_NUMBER 500000

// int -> hex
static char hexalphabet[]={'0','1','2','3','4','5','6','7','8','9','a','b','c','d','e','f'};

int hex2int(char c){
	switch(c){
		case '0': case '1': case '2': case '3': case '4':
		case '5': case '6': case '7': case '8': case '9': return c - '0';
		case 'a': case 'b': case 'c':
		case 'd': case 'e': case 'f': return c - 'a' + 10;
	}
	ERROR(hex2int,"Invalid hex character: %c\n",c);
	exit(1);
}

char tmpbuff_1[41];
char tmpbuff_2[41];
char tmpbuff_3[41];
char tmpbuff_4[41];

char* txtsha(unsigned char *sha1, char* outbuff){
	int fd;

	for (fd = 0; fd < 20; fd++){
		outbuff[fd*2] = hexalphabet[sha1[fd]>>4];
		outbuff[fd*2+1] = hexalphabet[sha1[fd]&0x0f];
	}
	outbuff[40] = '\0';
	return outbuff;
}

void shatxt(const char string[41], unsigned char outbuff[]) {
	int i;
	for(i=0; i < SHA_DIGEST_LENGTH; i++){
		outbuff[i] = hex2int(string[2*i]) * 16 + hex2int(string[2*i+1]);
	}
}

enum sight {
	SEEN=0, NOT_SEEN=1, MOVED=2, CHANGED=3
};

static char* sightalphabet[]={"SEEN","NOT_SEEN","MOVED","CHANGED"};

const char* strsight(enum sight s){
	return sightalphabet[s];
}

// mail metadata structure
struct mail {
	unsigned char bsha[SHA_DIGEST_LENGTH]; 	// body hash value
	unsigned char hsha[SHA_DIGEST_LENGTH]; 	// header hash value
	char *name;    							// file name
	time_t mtime;  							// modification time
	enum sight seen;     				// already seen (means do not delete)
};

// memory pool for mail file names
char *names;
long unsigned int curname, max_curname, old_curname;

// memory pool for mail metadata
struct mail* mails;
long unsigned int mailno, max_mailno;

// hash tables for fast comparison of mails given their name/body-hash
GHashTable *sha2mail;
GHashTable *filename2mail;

// program options
int verbose;

// =========================== memory allocator ============================

struct mail* alloc_mail(){
	struct mail* m = &mails[mailno];
	mailno++;
	if (mailno >= max_mailno) {
		mails = realloc(mails, sizeof(struct mail) * max_mailno * 2);
		if (mails == NULL){
			ERROR(realloc,"allocation failed for %lu mails\n", max_mailno * 2);
			exit(EXIT_FAILURE);
		}
		max_mailno *= 2;
	}
	return m;
}

void dealloc_mail(){
	mailno--;
}

#define MAX_EMAIL_NAME_LEN 1024

char *next_name(){
	return &names[curname];
}

char *alloc_name(){
	char *name = &names[curname];
	old_curname = curname;
	curname += strlen(name) + 1;
	if (curname + MAX_EMAIL_NAME_LEN > max_curname) {
		names = realloc(names, max_curname * 2);
		max_curname *= 2;
	}
	return name;
}

void dealloc_name(){
	curname = old_curname;
}

// =========================== global variables setup ======================

guint sha_hash(gconstpointer key){
	unsigned char * k = (unsigned char *) key;
	return k[0] + (k[1] << 8) + (k[2] << 16) + (k[3] << 24);
}

gboolean sha_equal(gconstpointer k1, gconstpointer k2){
	if(!memcmp(k1,k2,SHA_DIGEST_LENGTH)) return TRUE;
	else return FALSE;
}

// setup memory pools and hash tables
void setup_globals(unsigned long int mno, unsigned int fnlen){
	// allocate space for mail metadata
	mails = malloc(sizeof(struct mail) * mno);
	if (mails == NULL){
		ERROR(malloc,"allocation failed for %lu mails\n",mno);
		exit(EXIT_FAILURE);
	}
	mailno=0;
	max_mailno = mno;

	// allocate space for mail filenames
	names = malloc(mno * fnlen);
	if (names == NULL){
		ERROR(malloc, "memory allocation failed for %lu mails with an "
			"average filename length of %u\n",mailno,fnlen);
		exit(EXIT_FAILURE);
	}
	curname=0;
	max_curname=mno * fnlen;

	// allocate hashtables for detection of already available mails
	sha2mail = g_hash_table_new(sha_hash,sha_equal);
	if (sha2mail == NULL) {
		ERROR(sha2mail,"hashtable creation failure\n");
		exit(EXIT_FAILURE);
	}

	filename2mail = g_hash_table_new(g_str_hash,g_str_equal);
	if (filename2mail == NULL) {
		ERROR(filename2mail,"hashtable creation failure\n");
		exit(EXIT_FAILURE);
	}
}

// =========================== cache (de)serialization ======================

// dump to file the mailbox status
void save_db(const char* dbname){
	long unsigned int i;
	FILE * fd;
	char new_dbname[PATH_MAX];

	snprintf(new_dbname,PATH_MAX,"%s.new",dbname);

	fd = fopen(new_dbname,"w");
	if (fd == NULL){
		ERROR(fopen,"unable to save db file '%s'\n",new_dbname);
		exit(1);
	}

	for(i=0; i < mailno; i++){
		struct mail* m = &mails[i];
		if (m->seen == SEEN) {
			fprintf(fd,"%lu %s %s %s\n", m->mtime, 
				txtsha(m->hsha,tmpbuff_1), txtsha(m->bsha,tmpbuff_2), 
				m->name);
		}
	}

	fclose(fd);
}

// load from disk a mailbox status and index mails with hashtables
void load_db(const char* dbname){
	FILE* fd;
	int fields;
   
	fd = fopen(dbname,"r");
	if (fd == NULL) {
		ERROR(fopen,"unable to open db file '%s'\n",dbname);
		return;
	}

	for(;;) {
		// allocate a mail entry
		struct mail* m = alloc_mail();

		// read one entry
		fields = fscanf(fd,
			"%1$lu %2$40s %3$40s %4$" tostring(MAX_EMAIL_NAME_LEN) "s\n",
			&(m->mtime),  tmpbuff_1, tmpbuff_2, next_name());

		if (fields == EOF) {
			// deallocate mail entry
			dealloc_mail();
			break;
		}
		
		// sanity checks
		if (fields != 4) {
			ERROR(fscanf,"malformed db file '%s', please remove it\n",dbname);
			exit(EXIT_FAILURE);
		}

		shatxt(tmpbuff_1, m->hsha);
		shatxt(tmpbuff_2, m->bsha);

		// allocate a name string
		m->name = alloc_name();
		
		// not seen file, may be deleted
		m->seen=NOT_SEEN;

		// store it in the hash tables
		g_hash_table_insert(sha2mail,m->bsha,m);
		g_hash_table_insert(filename2mail,m->name,m);
		
	} 

	fclose(fd);
}

// =============================== commands ================================

#define COMMAND_SKIP(m) \
	VERBOSE(skip,"%s\n",m->name)

#define COMMAND_ADD(m) \
	fprintf(stdout,"ADD %s %s %s\n",m->name, \
		txtsha(m->hsha,tmpbuff_1), txtsha(m->bsha, tmpbuff_2))

#define COMMAND_COPY(m,n) \
	fprintf(stdout, "COPY %s %s %s TO %s\n",\
		m->name,txtsha(m->hsha, tmpbuff_1),\
		txtsha(m->bsha, tmpbuff_2),n->name)

#define COMMAND_DELETE(m) \
	fprintf(stdout,"DELETE %s %s %s\n",m->name, \
		txtsha(m->hsha, tmpbuff_1), txtsha(m->bsha, tmpbuff_2))
	
// TODO XXX change the implementation, names are useless since
// they are the same!
#define COMMAND_REPLACE(m,n) \
	fprintf(stdout, "REPLACE %s %s %s WITH %s %s %s\n",\
		m->name,txtsha(m->hsha,tmpbuff_1),txtsha(m->bsha,tmpbuff_2),\
		n->name,txtsha(n->hsha,tmpbuff_3),txtsha(n->bsha,tmpbuff_4))

#define COMMAND_REPLACE_HEADER(m,n) \
	fprintf(stdout, "REPLACEHEADER %s %s %s WITH %s\n",\
		m->name,txtsha(m->hsha,tmpbuff_1), txtsha(m->bsha,tmpbuff_2), \
					txtsha(n->hsha,tmpbuff_3))

// the hearth 
void analize_file(const char* dir,const char* file) {    
	char *addr,*next;
	int fd, header_found;
	struct stat sb;
	//unsigned char* sha1;
	struct mail* alias, *bodyalias, *m;
	gcry_md_hd_t gctx;

	m = alloc_mail();
	snprintf(next_name(), MAX_EMAIL_NAME_LEN,"%s/%s",dir,file);
	m->name = alloc_name();

	fd = open(m->name, O_RDONLY | O_NOATIME);
	if (fd == -1) {
		ERROR(open,"unable to open file '%s'\n",m->name);
		goto err_alloc_cleanup;
	}

	if (fstat(fd, &sb) == -1) {
		ERROR(fstat,"unable to stat file '%s'\n",m->name);
		goto err_alloc_cleanup;
	}

	m->mtime = sb.st_mtime;
	
	alias = (struct mail*)g_hash_table_lookup(filename2mail,m->name);

	// check if the cache lists a file with the same name and the same
	// mtime. if so, this is an old, untouched, message we can skip
	if (alias != NULL && alias->mtime == m->mtime) {
		alias->seen=SEEN;
		COMMAND_SKIP(alias);
		goto err_alloc_fd_cleanup;
	}

	addr = mmap(NULL, sb.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
	if (addr == MAP_FAILED){
		ERROR(mmap, "unable to load '%s'\n",m->name);
		if (sb.st_size == 0) 
			// empty file, we do not consider them emails
			goto err_alloc_fd_cleanup;
		else 
			// mmap failed, XXX add more verbose output
			exit(EXIT_FAILURE);
	}

	// skip header
	for(next = addr, header_found=0; next + 1 < addr + sb.st_size; next++){
		if (*next == '\n' && *(next+1) == '\n') {
			next+=2;
			header_found=1;
			break;
		}
	}

	if (!header_found) {
		ERROR(parse, "malformed file '%s', no header\n",m->name);
		munmap(addr, sb.st_size);
		goto err_alloc_fd_cleanup;
	}

	// calculate sha1
	gcry_md_open(&gctx, GCRY_MD_SHA1, 0);
	gcry_md_write(gctx, addr, next - addr);
	gcry_md_final(gctx);
	memcpy(m->hsha, gcry_md_read(gctx, 0), SHA_DIGEST_LENGTH);
	gcry_md_close(gctx);
	gcry_md_open(&gctx, GCRY_MD_SHA1, 0);
	gcry_md_write(gctx, next, sb.st_size - (next - addr));
	gcry_md_final(gctx);
	memcpy(m->bsha, gcry_md_read(gctx, 0), SHA_DIGEST_LENGTH);
	gcry_md_close(gctx);
	
	munmap(addr, sb.st_size);
	close(fd);

	if (alias != NULL) {
		if(sha_equal(alias->bsha,m->bsha)) {
			if (sha_equal(alias->hsha, m->hsha)) {
				alias->seen = m->seen = SEEN;
				return;
			} else {
				COMMAND_REPLACE_HEADER(alias,m);
				m->seen=SEEN;
				alias->seen=CHANGED;
				return;
			}
		} else {
			COMMAND_REPLACE(alias,m);
			m->seen=SEEN;
			alias->seen=CHANGED;
			return;
		}
	}

	bodyalias = g_hash_table_lookup(sha2mail,m->bsha);

	if (bodyalias != NULL) {
		if (sha_equal(bodyalias->hsha,m->hsha)) {
			COMMAND_COPY(bodyalias,m);
			m->seen=SEEN;
			return;
		}
	}

	// we should add that file
	COMMAND_ADD(m);
	m->seen=SEEN;
	return;

	// error handlers, status cleanup
err_alloc_fd_cleanup:
	close(fd);

err_alloc_cleanup:
	dealloc_name();
	dealloc_mail();
}
	
// recursively analyze a directory and its sub-directories
void analize_dir(const char* path){
	DIR* dir = opendir(path);
	struct dirent *dir_entry;

	if (dir == NULL) {
		fprintf(stderr, "Unable to open directory '%s'\n", path);
		exit(EXIT_FAILURE);
	}

	while ( (dir_entry = readdir(dir)) != NULL) {
		if (DT_REG == dir_entry->d_type)
			analize_file(path,dir_entry->d_name);
		else if (DT_DIR == dir_entry->d_type && 
				strcmp(dir_entry->d_name,"tmp") &&
				strcmp(dir_entry->d_name,".") &&
				strcmp(dir_entry->d_name,"..")){
			int len = strlen(path) + 1 + strlen(dir_entry->d_name) + 1;
			char * newdir = malloc(len);
			snprintf(newdir,len,"%s/%s",path,dir_entry->d_name);
			analize_dir(newdir);
			free(newdir);
		}
	}
}

void analize_dirs(char* paths[], int no){
	int i;
	for(i=0; i<no; i++){
		// we remove a trailing '/' if any 
		char *data = paths[i];
		if (data[strlen(data)-1] == '/') data[strlen(data)-1] = '\0';
		analize_dir(data);
	}
}

// at the end of the analysis phase, look at the mails data structure to
// identify mails that are not available anymore and should be removed
void generate_deletions(){
	long unsigned int i;

	for(i=0; i < mailno; i++){
		struct mail* m = &mails[i];
		if (m->seen == NOT_SEEN) 
			COMMAND_DELETE(m);
		else 
			VERBOSE(seen,"STATUS OF %s %s %s IS %s\n",
				m->name,txtsha(m->hsha,tmpbuff_1),
				txtsha(m->bsha,tmpbuff_2),strsight(m->seen));
	}
}

int extra_sha_file(const char* file) {    
	char *addr,*next;
	int fd, header_found;
	struct stat sb;
	//unsigned char* sha1;
	gcry_md_hd_t gctx;

	fd = open(file, O_RDONLY | O_NOATIME);
	if (fd == -1) {
		ERROR(open,"unable to open file '%s'\n",file);
		return 1;
	}

	if (fstat(fd, &sb) == -1) {
		ERROR(fstat,"unable to stat file '%s'\n",file);
		close(fd);
		return 2;
	}

	addr = mmap(NULL, sb.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
	if (addr == MAP_FAILED){
		ERROR(mmap, "unable to load '%s'\n",file);
		close(fd);
		return 3;
	}

	// skip header
	for(next = addr, header_found=0; next + 1 < addr + sb.st_size; next++){
		if (*next == '\n' && *(next+1) == '\n') {
			next+=2;
			header_found=1;
			break;
		}
	}

	if (!header_found) {
		ERROR(parse, "malformed file '%s', no header\n",file);
		munmap(addr, sb.st_size);
		close(fd);
		return 4;
	}

	// calculate sha1
	gcry_md_open(&gctx, GCRY_MD_SHA1, 0);
	gcry_md_write(gctx, addr, next - addr);
	gcry_md_final(gctx);
	fprintf(stdout, "%s ", txtsha(gcry_md_read(gctx, 0),tmpbuff_1));
	gcry_md_close(gctx);
	gcry_md_open(&gctx, GCRY_MD_SHA1, 0);
	gcry_md_write(gctx, next, sb.st_size - (next - addr));
	gcry_md_final(gctx);
	fprintf(stdout, "%s\n", txtsha(gcry_md_read(gctx, 0),tmpbuff_1));
	gcry_md_close(gctx);
	
	munmap(addr, sb.st_size);
	close(fd);
	return 0;
}


int extra_sha_files(char* file[],int no) {    
	int i;
	struct stat sb;
	for (i=0; i < no; i++){
		const char * data = file[i];
		int rc = stat(data, &sb);
		if (rc != 0) {
			ERROR(stat,"unable to stat %s\n",data);
			exit(EXIT_FAILURE);
		}
		if ( S_ISREG(sb.st_mode) ){
			rc = extra_sha_file(data);
			if (rc != 0) return rc;
		} else {
			ERROR(stat,"not a regular file '%s'\n",data);
			exit(EXIT_FAILURE);
		}
	}
	return 0;
}

// ============================ main =====================================

#define OPT_MAX_MAILNO 300
#define OPT_DB_FILE    301

// command line options
static struct option long_options[] = {
	{"max-mailno", 1, NULL, OPT_MAX_MAILNO},
	{"db-file"   , 1, NULL, OPT_DB_FILE}, 
	{"verbose"   , 0, NULL, 'v'},
	{"help"      , 0, NULL, 'h'},
	{NULL        , 0, NULL, 0}, 
};

// command line options documentation
const char* long_options_doc[] = {
	"Estimation of max mail message number (default " 
		tostring(DEFAULT_MAIL_NUMBER) ")"
		"\n                        " 
		"Decrease for small systems, it is increased"
		"\n                        " 
		"automatically if needed", 
	"Name of the cache for the endpoint (default db.txt)",
	"Increase program verbosity (printed on stderr, short -v)", 
	"This help screen", 
	NULL
};

// print help and bail out
void help(char* argv0, int rc){
	int i;
	char *bname = strdup(argv0);
	bname = basename(bname);

	fprintf(stdout,"\nUsage: %s [options] paths...\n",bname);
	for (i=0;long_options[i].name != NULL;i++) {
		fprintf(stdout,"  --%-20s%s\n",
			long_options[i].name,long_options_doc[i]);
	}
	fprintf(stdout,"\n\
If paths is a list of regular files, %s outputs the sha1 of its header\n\
and body separated by space.\n\n\
If paths is a list of directories, %s outputs a list of actions a client\n\
has to perform to syncronize a copy of the same maildir. This set of actions\n\
is relative to a previous status of the maildir stored in the db file.\n\
The input directories are traversed recursively, and every file encountered\n\
is a potential mail message (if it contains no \\n\\n it is skipped).\n\n\
Regular files and directories cannot be mixed in paths.\n\n\
Every client must use a different db-file, and the db-file is strictly\n\
related with the set of directories given as arguments, and should not\n\
be used with a different directory set. Adding items to the directory\n\
set is safe, while removing them may not do what you want (delete actions\n\
are generated).\n", bname, bname);
	fprintf(stdout,
		"\n© 2009 Enrico Tassi, released under GPLv3, no waranties\n\n");
	exit(rc);
}

int main(int argc, char *argv[]) {
	char *data;
	char *dbfile="db.txt";
	unsigned long int mailno = DEFAULT_MAIL_NUMBER;
	unsigned int filenamelen = DEFAULT_FILENAME_LEN;
	struct stat sb;
	int c = 0;
	int option_index = 0;

  	if (!gcry_check_version (GCRYPT_VERSION)) {
		fputs ("libgcrypt version mismatch\n", stderr);
		exit (2);
    }


	for(;;) {
		c = getopt_long(argc, argv, "vh", long_options, &option_index);
		if (c == -1) break; // no more args
		switch (c) {
			case OPT_MAX_MAILNO:
				mailno = strtoul(optarg,NULL,10);
			break;
			case OPT_DB_FILE:
				dbfile = strdup(optarg);
			break;
			case 'v':
				verbose = 1;
			break;
			case 'h':
				help(argv[0],EXIT_SUCCESS);
			break;
			default:
				help(argv[0],EXIT_FAILURE);
			break;
		}
	}

	if (optind >= argc) help(argv[0],EXIT_FAILURE);

	// remaining args is the dirs containing the data or the files to hash
	data = argv[optind];

	// check if data is a directory or a regular file
	c = stat(data, &sb);
	if (c != 0) {
		ERROR(stat,"unable to stat %s\n",data);
		exit(EXIT_FAILURE);
	}
	if ( S_ISREG(sb.st_mode) ){
		// simple mode, just hash the file
		return extra_sha_files(&argv[optind],argc - optind);
	} else if ( ! S_ISDIR(sb.st_mode) ) {
		ERROR(stat, "given path is not a regular file nor a directory: %s\n",
			data);
		exit(EXIT_FAILURE);
	}
	
	VERBOSE(init,"data directories are ");
	for(c=optind; c<argc - optind; c++) { VERBOSE_NOH(argv[c]);}	
	VERBOSE_NOH("\n");

	// allocate memory
	setup_globals(mailno,filenamelen);

	load_db(dbfile);

	analize_dirs(&argv[optind],argc - optind);

	generate_deletions();

	save_db(dbfile);

	exit(EXIT_SUCCESS);
}

// vim:set ts=4:
