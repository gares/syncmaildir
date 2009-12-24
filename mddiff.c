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
#include <limits.h>
#include <errno.h>
#include <string.h>
#include <fcntl.h>
#include <getopt.h>
#include <glib.h>

#ifndef O_NOATIME
# define O_NOATIME 0
#endif

#define STATIC static

#define SHA_DIGEST_LENGTH 20

#define __tostring(x) #x 
#define tostring(x) __tostring(x)

#define ERROR(cause, msg...) { \
	fprintf(stderr, "error [" tostring(cause) "]: " msg);\
	fprintf(stdout, "ERROR " msg);\
	exit(EXIT_FAILURE);\
	}
#define WARNING(cause, msg...) \
	fprintf(stderr, "warning [" tostring(cause) "]: " msg)
#define VERBOSE(cause,msg...) \
	if (verbose) fprintf(stderr,"debug [" tostring(cause) "]: " msg)
#define VERBOSE_NOH(msg...) \
	if (verbose) fprintf(stderr,msg)

// default numbers for static memory allocation
#define DEFAULT_FILENAME_LEN 100
#define DEFAULT_MAIL_NUMBER 500000

// int -> hex
STATIC char hexalphabet[] = 
	{'0','1','2','3','4','5','6','7','8','9','a','b','c','d','e','f'};

STATIC int hex2int(char c){
	switch(c){
		case '0': case '1': case '2': case '3': case '4':
		case '5': case '6': case '7': case '8': case '9': return c - '0';
		case 'a': case 'b': case 'c':
		case 'd': case 'e': case 'f': return c - 'a' + 10;
	}
	ERROR(hex2int,"Invalid hex character: %c\n",c);
}

// temporary buffers used to store sha1 sums in ASCII hex
STATIC char tmpbuff_1[SHA_DIGEST_LENGTH * 2 + 1];
STATIC char tmpbuff_2[SHA_DIGEST_LENGTH * 2 + 1];
STATIC char tmpbuff_3[SHA_DIGEST_LENGTH * 2 + 1];
STATIC char tmpbuff_4[SHA_DIGEST_LENGTH * 2 + 1];

STATIC char* txtsha(unsigned char *sha1, char* outbuff){
	int fd;

	for (fd = 0; fd < 20; fd++){
		outbuff[fd*2] = hexalphabet[sha1[fd]>>4];
		outbuff[fd*2+1] = hexalphabet[sha1[fd]&0x0f];
	}
	outbuff[40] = '\0';
	return outbuff;
}

STATIC void shatxt(const char string[41], unsigned char outbuff[]) {
	int i;
	for(i=0; i < SHA_DIGEST_LENGTH; i++){
		outbuff[i] = hex2int(string[2*i]) * 16 + hex2int(string[2*i+1]);
	}
}

// flags used to mark struct mail so that at the end of the scanning 
// we output commands lookig that flag
enum sight {
	SEEN=0, NOT_SEEN=1, MOVED=2, CHANGED=3
};

STATIC char* sightalphabet[]={"SEEN","NOT_SEEN","MOVED","CHANGED"};

STATIC const char* strsight(enum sight s){
	return sightalphabet[s];
}

// mail metadata structure
struct mail {
	unsigned char bsha[SHA_DIGEST_LENGTH]; 	// body hash value
	unsigned char hsha[SHA_DIGEST_LENGTH]; 	// header hash value
	char *name;    							// file name
	enum sight seen;     			        // already seen?
};

// memory pool for mail file names
STATIC char *names;
STATIC long unsigned int curname, max_curname, old_curname;

// memory pool for mail metadata
STATIC struct mail* mails;
STATIC long unsigned int mailno, max_mailno;

// hash tables for fast comparison of mails given their name/body-hash
STATIC GHashTable *sha2mail;
STATIC GHashTable *filename2mail;
STATIC time_t lastcheck;

// program options
STATIC int verbose;

// ============================ helpers =====================================

STATIC int directory(struct stat sb){ return S_ISDIR(sb.st_mode); }
STATIC int regular_file(struct stat sb){ return S_ISREG(sb.st_mode); }

// stats and asserts pred on argv[optind] ... argv[argc-optind]
STATIC void assert_all_are(
	int(*predicate)(struct stat), char* description, char*argv[], int argc)
{
	struct stat sb;
	int c, rc;
	VERBOSE(input, "Asserting all input paths are: %s\n", description);
	for(c = 0; c < argc; c++) { 
		rc = stat(argv[c], &sb);
		if (rc != 0) {
			ERROR(stat,"unable to stat %s\n",argv[c]);
		} else if ( ! predicate(sb) ) {
			ERROR(stat,"%s in not a %s, arguments must be omogeneous\n",
				argv[c],description);
		}
		VERBOSE(input, "%s is a %s\n", argv[c], description);
	}
}
#define ASSERT_ALL_ARE(what,v,c) assert_all_are(what,tostring(what),v,c)

// =========================== memory allocator ============================

STATIC struct mail* alloc_mail(){
	struct mail* m = &mails[mailno];
	mailno++;
	if (mailno >= max_mailno) {
		mails = realloc(mails, sizeof(struct mail) * max_mailno * 2);
		if (mails == NULL){
			ERROR(realloc,"allocation failed for %lu mails\n", max_mailno * 2);
		}
		max_mailno *= 2;
	}
	return m;
}

STATIC void dealloc_mail(){
	mailno--;
}

#define MAX_EMAIL_NAME_LEN 1024

STATIC char *next_name(){
	return &names[curname];
}

STATIC char *alloc_name(){
	char *name = &names[curname];
	old_curname = curname;
	curname += strlen(name) + 1;
	if (curname + MAX_EMAIL_NAME_LEN > max_curname) {
		names = realloc(names, max_curname * 2);
		max_curname *= 2;
	}
	return name;
}

STATIC void dealloc_name(){
	curname = old_curname;
}

// =========================== global variables setup ======================

STATIC guint sha_hash(gconstpointer key){
	unsigned char * k = (unsigned char *) key;
	return k[0] + (k[1] << 8) + (k[2] << 16) + (k[3] << 24);
}

STATIC gboolean sha_equal(gconstpointer k1, gconstpointer k2){
	if(!memcmp(k1,k2,SHA_DIGEST_LENGTH)) return TRUE;
	else return FALSE;
}

// setup memory pools and hash tables
STATIC void setup_globals(unsigned long int mno, unsigned int fnlen){
	// allocate space for mail metadata
	mails = malloc(sizeof(struct mail) * mno);
	if (mails == NULL) ERROR(malloc,"allocation failed for %lu mails\n",mno);
	
	mailno=0;
	max_mailno = mno;

	// allocate space for mail filenames
	names = malloc(mno * fnlen);
	if (names == NULL)
		ERROR(malloc, "memory allocation failed for %lu mails with an "
			"average filename length of %u\n",mailno,fnlen);

	curname=0;
	max_curname=mno * fnlen;

	// allocate hashtables for detection of already available mails
	sha2mail = g_hash_table_new(sha_hash,sha_equal);
	if (sha2mail == NULL) ERROR(sha2mail,"hashtable creation failure\n");

	filename2mail = g_hash_table_new(g_str_hash,g_str_equal);
	if (filename2mail == NULL) 
		ERROR(filename2mail,"hashtable creation failure\n");
}

// =========================== cache (de)serialization ======================

// dump to file the mailbox status
STATIC void save_db(const char* dbname, time_t timestamp){
	long unsigned int i;
	FILE * fd;
	char new_dbname[PATH_MAX];

	snprintf(new_dbname,PATH_MAX,"%s.new",dbname);

	fd = fopen(new_dbname,"w");
	if (fd == NULL) ERROR(fopen,"unable to save db file '%s'\n",new_dbname);

	for(i=0; i < mailno; i++){
		struct mail* m = &mails[i];
		if (m->seen == SEEN) {
			fprintf(fd,"%s %s %s\n", 
				txtsha(m->hsha,tmpbuff_1), txtsha(m->bsha,tmpbuff_2), 
				m->name);
		}
	}

	fclose(fd);

	snprintf(new_dbname,PATH_MAX,"%s.mtime",dbname);

	fd = fopen(new_dbname,"w");
	if (fd == NULL) ERROR(fopen,"unable to save db file '%s'\n",new_dbname);

	fprintf(fd,"%lu",timestamp);

	fclose(fd);
}

// load from disk a mailbox status and index mails with hashtables
STATIC void load_db(const char* dbname){
	FILE* fd;
	int fields;
	char new_dbname[PATH_MAX];

	snprintf(new_dbname,PATH_MAX,"%s.mtime",dbname);

	fd = fopen(new_dbname,"r");
	if (fd == NULL){
		WARNING(fopen,"unable to load db file '%s'\n",new_dbname);
		lastcheck = 0L;
	} else {
		fields = fscanf(fd,"%1$lu",&lastcheck);
		if (fields != 1) 
			ERROR(fscanf,"malformed db file '%s', please remove it\n",
				new_dbname);

		fclose(fd);
	}
   
	fd = fopen(dbname,"r");
	if (fd == NULL) {
		WARNING(fopen,"unable to open db file '%s'\n",dbname);
		return;
	}

	for(;;) {
		// allocate a mail entry
		struct mail* m = alloc_mail();

		// read one entry
		fields = fscanf(fd,
			"%1$40s %2$40s %3$" tostring(MAX_EMAIL_NAME_LEN) "s\n",
			tmpbuff_1, tmpbuff_2, next_name());

		if (fields == EOF) {
			// deallocate mail entry
			dealloc_mail();
			break;
		}
		
		// sanity checks
		if (fields != 3)
			ERROR(fscanf,"malformed db file '%s', please remove it\n",dbname);

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

#define COMMAND_COPYBODY(m,n) \
	fprintf(stdout, "COPYBODY %s %s TO %s %s\n",\
		m->name,txtsha(m->bsha, tmpbuff_1),\
		n->name,txtsha(n->hsha, tmpbuff_2))

#define COMMAND_DELETE(m) \
	fprintf(stdout,"DELETE %s %s %s\n",m->name, \
		txtsha(m->hsha, tmpbuff_1), txtsha(m->bsha, tmpbuff_2))
	
#define COMMAND_REPLACE(m,n) \
	fprintf(stdout, "REPLACE %s %s %s WITH %s %s\n",\
		m->name,txtsha(m->hsha,tmpbuff_1),txtsha(m->bsha,tmpbuff_2),\
		txtsha(n->hsha,tmpbuff_3),txtsha(n->bsha,tmpbuff_4))

#define COMMAND_REPLACE_HEADER(m,n) \
	fprintf(stdout, "REPLACEHEADER %s %s %s WITH %s\n",\
		m->name,txtsha(m->hsha,tmpbuff_1), txtsha(m->bsha,tmpbuff_2), \
					txtsha(n->hsha,tmpbuff_3))

// the hearth 
STATIC void analize_file(const char* dir,const char* file) {    
	unsigned char *addr,*next;
	int fd, header_found;
	struct stat sb;
	struct mail* alias, *bodyalias, *m;
	GChecksum* ctx;
	gsize ctx_len;

	m = alloc_mail();
	snprintf(next_name(), MAX_EMAIL_NAME_LEN,"%s/%s",dir,file);
	m->name = alloc_name();

	fd = open(m->name, O_RDONLY | O_NOATIME);
	if (fd == -1) {
		WARNING(open,"unable to open file '%s'\n",m->name);
		goto err_alloc_cleanup;
	}

	if (fstat(fd, &sb) == -1) {
		WARNING(fstat,"unable to stat file '%s'\n",m->name);
		goto err_alloc_cleanup;
	}

	alias = (struct mail*)g_hash_table_lookup(filename2mail,m->name);

	// check if the cache lists a file with the same name and the same
	// mtime. If so, this is an old, untouched, message we can skip
	if (alias != NULL && lastcheck > sb.st_mtime) {
		alias->seen=SEEN;
		COMMAND_SKIP(alias);
		goto err_alloc_fd_cleanup;
	}

	addr = mmap(NULL, sb.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
	if (addr == MAP_FAILED){
		if (sb.st_size == 0) 
			// empty file, we do not consider them emails
			goto err_alloc_fd_cleanup;
		else 
			// mmap failed
			ERROR(mmap, "unable to load '%s'\n",m->name);
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
		WARNING(parse, "malformed file '%s', no header\n",m->name);
		munmap(addr, sb.st_size);
		goto err_alloc_fd_cleanup;
	}

	// calculate sha1
	ctx = g_checksum_new(G_CHECKSUM_SHA1);
	ctx_len = SHA_DIGEST_LENGTH;
	g_checksum_update(ctx, addr, next - addr);
	g_checksum_get_digest(ctx, m->hsha, &ctx_len);
	g_checksum_free(ctx);

	ctx = g_checksum_new(G_CHECKSUM_SHA1);
	ctx_len = SHA_DIGEST_LENGTH;
	g_checksum_update(ctx, next, sb.st_size - (next - addr));
	g_checksum_get_digest(ctx, m->bsha, &ctx_len);
	g_checksum_free(ctx);

	munmap(addr, sb.st_size);
	close(fd);

	if (alias != NULL) {
		if(sha_equal(alias->bsha,m->bsha)) {
			if (sha_equal(alias->hsha, m->hsha)) {
				alias->seen = SEEN;
				goto err_alloc_fd_cleanup;
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
		} else {
			COMMAND_COPYBODY(bodyalias,m);
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
STATIC void analize_dir(const char* path){
	DIR* dir = opendir(path);
	struct dirent *dir_entry;

	if (dir == NULL) ERROR(opendir, "Unable to open directory '%s'\n", path);

	while ( (dir_entry = readdir(dir)) != NULL) {
		if (DT_REG == dir_entry->d_type){
#ifdef __GLIBC__ 
			const char* bname = basename(path);	
#else
			gchar* bname = g_path_get_basename(path);	
#endif
			if ( !strcmp(bname,"cur") || !strcmp(bname,"new"))
				analize_file(path,dir_entry->d_name);
			else
				VERBOSE(analize_dir,"skipping '%s/%s', outside maildir\n",
					path,dir_entry->d_name);
#ifndef __GLIBC__ 
			g_free(bname);
#endif
		} else if (DT_DIR == dir_entry->d_type && 
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

STATIC void analize_dirs(char* paths[], int no){
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
STATIC void generate_deletions(){
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

STATIC void extra_sha_file(const char* file) {    
	unsigned char *addr,*next;
	int fd, header_found;
	struct stat sb;
	gchar* sha1;

	fd = open(file, O_RDONLY | O_NOATIME);
	if (fd == -1) ERROR(open,"unable to open file '%s'\n",file);

	if (fstat(fd, &sb) == -1) ERROR(fstat,"unable to stat file '%s'\n",file);

	addr = mmap(NULL, sb.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
	if (addr == MAP_FAILED) ERROR(mmap, "unable to load '%s'\n",file);

	// skip header
	for(next = addr, header_found=0; next + 1 < addr + sb.st_size; next++){
		if (*next == '\n' && *(next+1) == '\n') {
			next+=2;
			header_found=1;
			break;
		}
	}

	if (!header_found) ERROR(parse, "malformed file '%s', no header\n",file);

	// calculate sha1
	fprintf(stdout, "%s ", 
		sha1 = g_compute_checksum_for_data(G_CHECKSUM_SHA1, addr, next - addr));
	g_free(sha1);
	fprintf(stdout, "%s\n", 
		sha1 = g_compute_checksum_for_data(G_CHECKSUM_SHA1, 
				next, sb.st_size - (next - addr)));
	g_free(sha1);
	
	munmap(addr, sb.st_size);
	close(fd);
}


STATIC void extra_sha_files(char* file[], int no) {    
	int i;
	for (i=0; i < no; i++) extra_sha_file(file[i]);
}

// ============================ main =====================================

#define OPT_MAX_MAILNO 300
#define OPT_DB_FILE    301

// command line options
STATIC struct option long_options[] = {
	{"max-mailno", 1, NULL, OPT_MAX_MAILNO},
	{"db-file"   , 1, NULL, OPT_DB_FILE}, 
	{"verbose"   , 0, NULL, 'v'},
	{"help"      , 0, NULL, 'h'},
	{NULL        , 0, NULL, 0}, 
};

// command line options documentation
STATIC const char* long_options_doc[] = {
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
STATIC void help(char* argv0){
	int i;
	char *bname = g_path_get_basename(argv0);

	fprintf(stdout,"\nUsage: %s [options] paths...\n",bname);
	for (i=0;long_options[i].name != NULL;i++) {
		fprintf(stdout,"  --%-20s%s\n",
			long_options[i].name,long_options_doc[i]);
	}
	fprintf(stdout,"\n\
If paths is a list of regular files, %s outputs the sha1 of its header\n\
and body separated by space.\n\n\
If paths is a list of directories, %s outputs a list of actions a client\n\
has to perform to syncronize a copy of the same maildirs. This set of actions\n\
is relative to a previous status of the maildir stored in the db file.\n\
The input directories are traversed recursively, and every file encountered\n\
inside directories named cur/ and new/ is a potential mail message (if it\n\
contains no \\n\\n it is skipped).\n\n\
Regular files and directories cannot be mixed in paths.\n\n\
Every client must use a different db-file, and the db-file is strictly\n\
related with the set of directories given as arguments, and should not\n\
be used with a different directory set. Adding items to the directory\n\
set is safe, while removing them may not do what you want (delete actions\n\
are generated).\n", bname, bname);
	fprintf(stdout,
		"\nVersion %s, © 2009 Enrico Tassi, released under GPLv3, \
no waranties\n\n",tostring(VERSION));
}

int main(int argc, char *argv[]) {
	char *data;
	char *dbfile="db.txt";
	unsigned long int mailno = DEFAULT_MAIL_NUMBER;
	unsigned int filenamelen = DEFAULT_FILENAME_LEN;
	struct stat sb;
	int c = 0;
	int option_index = 0;
	time_t bigbang;

	glib_check_version(2,16,0);

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
				help(argv[0]);
				exit(EXIT_SUCCESS);
			break;
			default:
				help(argv[0]);
				exit(EXIT_FAILURE);
			break;
		}
	}

	if (optind >= argc) { 
		help(argv[0]);
		exit(EXIT_FAILURE);
	}

	// remaining args is the dirs containing the data or the files to hash
	data = argv[optind];

	// check if data is a directory or a regular file
	c = stat(data, &sb);
	if (c != 0) ERROR(stat,"unable to stat %s\n",data);
	
	if ( S_ISREG(sb.st_mode) ){
		// simple mode, just hash the files
		ASSERT_ALL_ARE(regular_file, &argv[optind], argc - optind);
		extra_sha_files(&argv[optind], argc - optind);
		exit(EXIT_SUCCESS);
	} else if ( ! S_ISDIR(sb.st_mode) ) {
		ERROR(stat, "given path is not a regular file or directory: %s\n",data);
	}
	
	// regular case, hash the content of maildirs rooted in the 
	// list of directories specified at command line
	ASSERT_ALL_ARE(directory, &argv[optind], argc - optind);

	// allocate memory
	setup_globals(mailno,filenamelen);

	load_db(dbfile);

	bigbang = time(NULL);
	analize_dirs(&argv[optind],argc - optind);

	generate_deletions();

	save_db(dbfile, bigbang);

	exit(EXIT_SUCCESS);
}

// vim:set ts=4:
