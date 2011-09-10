//
// maildir diff (mddiff) computes the delta from an old status of a maildir
// (previously recorded in a support file) and the current status, generating
// a set of commands (a diff) that a third party software can apply to
// synchronize a (remote) copy of the maildir.
//
// Absolutely no warranties, released under GNU GPL version 3 or at your 
// option any later version.
//
// Copyright 2008-2010 Enrico Tassi <gares@fettunta.org>

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
#include <fnmatch.h>
#include <glib.h>

#include "smd-config.h"

#ifndef O_NOATIME
# define O_NOATIME 0
#endif

// C99 has a printf length modifier for size_t
#if __STDC_VERSION__ >= 199901L
	#define SIZE_T_FMT "%zu"
	#define SIZE_T_CAST(x) x
#else
	#define SIZE_T_FMT "%lu"
	#define SIZE_T_CAST(x) ((unsigned long)x)
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
#define MAX_EMAIL_NAME_LEN 1024

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

// temporary buffers used to URL encode mail names
STATIC char tmpbuff_5[MAX_EMAIL_NAME_LEN];
STATIC char tmpbuff_6[MAX_EMAIL_NAME_LEN];

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

STATIC char* URLtxt(const char string[], char outbuff[]) {
	size_t i,j;
	size_t len = strlen(string);
	for(i=0, j=0; i < len && j + 4 < MAX_EMAIL_NAME_LEN; i++, j++) {
		if (string[i] == ' ' || string[i] == '%') {
			snprintf(&outbuff[j], 4, "%%%X", string[i]);
			j+=2;
		} else {
			outbuff[j] = string[i];
		}
	}
	outbuff[j] = '\0';
	return outbuff;
}

STATIC char* txtURL(const char* string, char* outbuff) {
	size_t i,j;
	size_t len = strlen(string);
	for(i=0, j=0; i < len && j + 4 < MAX_EMAIL_NAME_LEN; i++, j++) {
		if (string[i] == '%' && i + 2 < len) {
			unsigned int k;
			sscanf(&string[i+1],"%2x",&k);
			snprintf(&outbuff[j], 2, "%c", k);
			i+=2;
		} else {
			outbuff[j] = string[i];
		}
	}
	outbuff[j] = '\0';
	return outbuff;
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

// since the mails and names buffers may be reallocated,
// hashtables cannot record pointers to a struct mail or char.
// they record the offset w.r.t. the base pointer of the buffers.
// we define a type for them, so that the compiler complains loudly
typedef size_t name_t;
typedef size_t mail_t;

// mail metadata structure
struct mail {
	unsigned char bsha[SHA_DIGEST_LENGTH]; 	// body hash value
	unsigned char hsha[SHA_DIGEST_LENGTH]; 	// header hash value
	name_t __name;    						// file name, do not use directly
	enum sight seen;     			        // already seen?
};

// memory pool for mail file names
STATIC char *names;
STATIC name_t curname, max_curname, old_curname;

// memory pool for mail metadata
STATIC struct mail* mails;
STATIC mail_t mailno, max_mailno;

// hash tables for fast comparison of mails given their name/body-hash
STATIC GHashTable *bsha2mail;
STATIC GHashTable *filename2mail;
STATIC time_t lastcheck;

// program options
STATIC int verbose;
STATIC int dry_run;
STATIC int only_list_subfolders;
STATIC int only_generate_symlinks;
STATIC int n_excludes;
STATIC char **excludes;

// ============================ helpers =====================================

// mail da structure accessors
STATIC struct mail* mail(mail_t mail_idx) {
	return &mails[mail_idx];
}

STATIC char* mail_name(mail_t mail_idx) {
	return &names[mails[mail_idx].__name];
}

STATIC void set_mail_name(mail_t mail_idx, name_t name) {
	mails[mail_idx].__name = name;
}

// predicates for assert_all_are
STATIC int directory(struct stat sb){ return S_ISDIR(sb.st_mode); }

// stats and asserts pred on argv[optind] ... argv[argc-optind]
STATIC void assert_all_are(
	int(*predicate)(struct stat), char* description, char*argv[], int argc)
{
	struct stat sb;
	int c, rc;
	VERBOSE(input, "Asserting all input paths are: %s\n", description);
	for(c = 0; c < argc; c++) { 
		const char * argv_c = txtURL(argv[c], tmpbuff_5);
		rc = stat(argv_c, &sb);
		if (rc != 0) {
			ERROR(stat,"unable to stat %s\n",argv_c);
		} else if ( ! predicate(sb) ) {
			ERROR(stat,"%s in not a %s, arguments must be omogeneous\n",
				argv_c,description);
		}
		VERBOSE(input, "%s is a %s\n", argv_c, description);
	}
}
#define ASSERT_ALL_ARE(what,v,c) assert_all_are(what,tostring(what),v,c)

// =========================== memory allocator ============================

STATIC mail_t alloc_mail(){
	mail_t m = mailno;
	mailno++;
	if (mailno >= max_mailno) {
		mails = realloc(mails, sizeof(struct mail) * max_mailno * 2);
		if (mails == NULL){
			ERROR(realloc,"allocation failed for " SIZE_T_FMT " mails\n", 
				SIZE_T_CAST(max_mailno * 2));
		}
		max_mailno *= 2;
	}
	return m;
}

STATIC void dealloc_mail(){
	mailno--;
}

STATIC char *next_name(){
	return &names[curname];
}

STATIC name_t alloc_name(){
	name_t name = curname;
	size_t len = strlen(&names[name]);
	old_curname = curname;
	curname += len + 1;
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

// convenience casts to be used with glib hashtables 
#define MAIL(t) ((mail_t)(t))
#define GPTR(t) ((gpointer)(t))

STATIC guint bsha_hash(gconstpointer key){
	mail_t m = MAIL(key);
	unsigned char * k = (unsigned char *) mail(m)->bsha;
	return k[0] + (k[1] << 8) + (k[2] << 16) + (k[3] << 24);
}

STATIC gboolean bsha_equal(gconstpointer k1, gconstpointer k2){
	mail_t m1 = MAIL(k1);
	mail_t m2 = MAIL(k2);
	if(!memcmp(mail(m1)->bsha,mail(m2)->bsha,SHA_DIGEST_LENGTH)) return TRUE;
	else return FALSE;
}

STATIC gboolean hsha_equal(gconstpointer k1, gconstpointer k2){
	mail_t m1 = MAIL(k1);
	mail_t m2 = MAIL(k2);
	if(!memcmp(mail(m1)->hsha,mail(m2)->hsha,SHA_DIGEST_LENGTH)) return TRUE;
	else return FALSE;
}

STATIC guint name_hash(gconstpointer key){
	mail_t m = MAIL(key);
	return g_str_hash(mail_name(m));
}

STATIC gboolean name_equal(gconstpointer k1, gconstpointer k2){
	mail_t m1 = MAIL(k1);
	mail_t m2 = MAIL(k2);
	return g_str_equal(mail_name(m1), mail_name(m2));
}

// wc -l, returning 0 on error
STATIC unsigned long int wc_l(const char* dbfile){
	int unsigned long mno = 0;
	struct stat sb;
	unsigned char *addr, *next;
	int fd;
	if ((fd = open(dbfile, O_RDONLY | O_NOATIME)) == -1) goto err_open;
	if (fstat(fd, &sb) == -1) goto err_mmap;
	if ((addr = mmap(NULL, sb.st_size, PROT_READ, MAP_PRIVATE, fd, 0))
		== MAP_FAILED) goto err_mmap;

	for(next = addr; next < addr + sb.st_size; next++){
		if (*next == '\n') mno++;
	}

	munmap(addr, sb.st_size);
	close(fd);
	return mno;

	err_mmap:
		close(fd);
	err_open:
		return 0;
}

// setup memory pools and hash tables
STATIC void setup_globals(
		const char *dbfile, unsigned long int mno, unsigned int fnlen){
	// we try to guess a reasonable number of email, to avoid asking the
	// allocator an unnnecessarily big chunk whose allocation may fail if there
	// is too few memory. We compute the number of entries in the db-file and
	// we add 1000 speculating not more than 1000 mails will be received.
	if (mno == 0){
		if ((mno = wc_l(dbfile)) == 0) mno = DEFAULT_MAIL_NUMBER;
		else mno += 1000;
		VERBOSE(setup_globals, "guessing we need space for %lu mails\n", mno);
	}

	// allocate space for mail metadata
	mails = malloc(sizeof(struct mail) * mno);
	if (mails == NULL) ERROR(malloc,"allocation failed for %lu mails\n",mno);
	
	mailno=1; // 0 is reserved for NULL
	max_mailno = mno;

	// allocate space for mail filenames
	names = malloc(mno * fnlen);
	if (names == NULL)
		ERROR(malloc, "memory allocation failed for " SIZE_T_FMT 
			" mails with an average filename length of %u\n",
			SIZE_T_CAST(mailno),fnlen);

	curname=0;
	max_curname=mno * fnlen;

	// allocate hashtables for detection of already available mails
	bsha2mail = g_hash_table_new(bsha_hash,bsha_equal);
	if (bsha2mail == NULL) ERROR(bsha2mail,"hashtable creation failure\n");

	filename2mail = g_hash_table_new(name_hash,name_equal);
	if (filename2mail == NULL) 
		ERROR(filename2mail,"hashtable creation failure\n");
}

// =========================== cache (de)serialization ======================

// dump to file the mailbox status
STATIC void save_db(const char* dbname, time_t timestamp){
	mail_t m;
	FILE * fd;
	char new_dbname[PATH_MAX];

	snprintf(new_dbname,PATH_MAX,"%s.new",dbname);

	fd = fopen(new_dbname,"w");
	if (fd == NULL) ERROR(fopen,"unable to save db file '%s'\n",new_dbname);

	for(m=1; m < mailno; m++){
		if (mail(m)->seen == SEEN) {
			fprintf(fd,"%s %s %s\n", 
				txtsha(mail(m)->hsha,tmpbuff_1), 
				txtsha(mail(m)->bsha,tmpbuff_2), 
				mail_name(m));
		}
	}

	fclose(fd);

	snprintf(new_dbname,PATH_MAX,"%s.mtime.new",dbname);

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
		mail_t m = alloc_mail();

		// read one entry
		fields = fscanf(fd,
			"%1$40s %2$40s %3$" tostring(MAX_EMAIL_NAME_LEN) "[^\n]\n",
			tmpbuff_1, tmpbuff_2, next_name());

		if (fields == EOF) {
			// deallocate mail entry
			dealloc_mail();
			break;
		}
		
		// sanity checks
		if (fields != 3)
			ERROR(fscanf,"malformed db file '%s', please remove it\n",dbname);

		shatxt(tmpbuff_1, mail(m)->hsha);
		shatxt(tmpbuff_2, mail(m)->bsha);

		// allocate a name string
		set_mail_name(m,alloc_name());
		
		// not seen file, may be deleted
		mail(m)->seen=NOT_SEEN;

		// store it in the hash tables
		g_hash_table_insert(bsha2mail,GPTR(m),GPTR(m));
		g_hash_table_insert(filename2mail,GPTR(m),GPTR(m));
		
	} 

	fclose(fd);
}

// =============================== commands ================================

#define COMMAND_SKIP(m) \
	VERBOSE(skip,"%s\n",mail_name(m))

#define COMMAND_ADD(m) \
	fprintf(stdout,"ADD %s %s %s\n", URLtxt(mail_name(m),tmpbuff_5),\
		txtsha(mail(m)->hsha,tmpbuff_1),\
		txtsha(mail(m)->bsha, tmpbuff_2))

#define COMMAND_COPY(m,n) \
	fprintf(stdout, "COPY %s %s %s TO %s\n", URLtxt(mail_name(m),tmpbuff_5),\
		txtsha(mail(m)->hsha, tmpbuff_1),\
		txtsha(mail(m)->bsha, tmpbuff_2),\
		URLtxt(mail_name(n),tmpbuff_6))

#define COMMAND_COPYBODY(m,n) \
	fprintf(stdout, "COPYBODY %s %s TO %s %s\n",\
		URLtxt(mail_name(m),tmpbuff_5),txtsha(mail(m)->bsha, tmpbuff_1),\
		URLtxt(mail_name(n),tmpbuff_6),txtsha(mail(n)->hsha, tmpbuff_2))

#define COMMAND_DELETE(m) \
	fprintf(stdout,"DELETE %s %s %s\n", URLtxt(mail_name(m),tmpbuff_5), \
		txtsha(mail(m)->hsha, tmpbuff_1), txtsha(mail(m)->bsha, tmpbuff_2))
	
#define COMMAND_REPLACE(m,n) \
	fprintf(stdout, "REPLACE %s %s %s WITH %s %s\n",\
		URLtxt(mail_name(m),tmpbuff_5),txtsha(mail(m)->hsha,tmpbuff_1),\
		txtsha(mail(m)->bsha,tmpbuff_2),\
		txtsha(mail(n)->hsha,tmpbuff_3),txtsha(mail(n)->bsha,tmpbuff_4))

#define COMMAND_REPLACE_HEADER(m,n) \
	fprintf(stdout, "REPLACEHEADER %s %s %s WITH %s\n",\
		mail_name(m),txtsha(mail(m)->hsha,tmpbuff_1),\
		txtsha(mail(m)->bsha,tmpbuff_2), \
		txtsha(mail(n)->hsha,tmpbuff_3))

// the heart
STATIC void analyze_file(const char* dir,const char* file) {    
	unsigned char *addr,*next;
	int fd, header_found;
	struct stat sb;
	mail_t alias, bodyalias, m;
	GChecksum* ctx;
	gsize ctx_len;

	m = alloc_mail();
	snprintf(next_name(), MAX_EMAIL_NAME_LEN,"%s/%s",dir,file);
	set_mail_name(m,alloc_name());

	fd = open(mail_name(m), O_RDONLY | O_NOATIME);
	if (fd == -1) {
		if (errno == EPERM) {
			// if the file is not owned by the euid of the process, then
			// it cannot be opened using the O_NOATIME flag (man 2 open)
			fd = open(mail_name(m), O_RDONLY);
		}
		if (fd == -1) {
			WARNING(open,"unable to open file '%s': %s\n", mail_name(m),
				strerror(errno));
			WARNING(open,"ignoring '%s'\n", mail_name(m));
			goto err_alloc_cleanup;
		}
	}

	if (fstat(fd, &sb) == -1) {
		WARNING(fstat,"unable to stat file '%s'\n",mail_name(m));
		goto err_alloc_cleanup;
	}

	alias = MAIL(g_hash_table_lookup(filename2mail,GPTR(m)));

	// check if the cache lists a file with the same name and the same
	// mtime. If so, this is an old, untouched, message we can skip
	if (alias != 0 && lastcheck > sb.st_mtime) {
		mail(alias)->seen=SEEN;
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
			ERROR(mmap, "unable to load '%s'\n",mail_name(m));
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
		WARNING(parse, "malformed file '%s', no header\n",mail_name(m));
		munmap(addr, sb.st_size);
		goto err_alloc_fd_cleanup;
	}

	// calculate sha1
	ctx = g_checksum_new(G_CHECKSUM_SHA1);
	ctx_len = SHA_DIGEST_LENGTH;
	g_checksum_update(ctx, addr, next - addr);
	g_checksum_get_digest(ctx, mail(m)->hsha, &ctx_len);
	g_checksum_free(ctx);

	ctx = g_checksum_new(G_CHECKSUM_SHA1);
	ctx_len = SHA_DIGEST_LENGTH;
	g_checksum_update(ctx, next, sb.st_size - (next - addr));
	g_checksum_get_digest(ctx, mail(m)->bsha, &ctx_len);
	g_checksum_free(ctx);

	munmap(addr, sb.st_size);
	close(fd);

	if (alias != 0) {
		if(bsha_equal(GPTR(alias),GPTR(m))) {
			if (hsha_equal(GPTR(alias), GPTR(m))) {
				mail(alias)->seen = SEEN;
				goto err_alloc_fd_cleanup;
			} else {
				COMMAND_REPLACE_HEADER(alias,m);
				mail(m)->seen=SEEN;
				mail(alias)->seen=CHANGED;
				return;
			}
		} else {
			COMMAND_REPLACE(alias,m);
			mail(m)->seen=SEEN;
			mail(alias)->seen=CHANGED;
			return;
		}
	}

	bodyalias = MAIL(g_hash_table_lookup(bsha2mail,GPTR(m)));

	if (bodyalias != 0) {
		if (hsha_equal(GPTR(bodyalias), GPTR(m))) {
			COMMAND_COPY(bodyalias,m);
			mail(m)->seen=SEEN;
			return;
		} else {
			COMMAND_COPYBODY(bodyalias,m);
			mail(m)->seen=SEEN;
			return;
		}
	}

	// we should add that file
	COMMAND_ADD(m);
	mail(m)->seen=SEEN;
	return;

	// error handlers, status cleanup
err_alloc_fd_cleanup:
	close(fd);

err_alloc_cleanup:
	dealloc_name();
	dealloc_mail();
}
	
// recursively analyze a directory and its sub-directories
STATIC void analyze_dir(const char* path){
	DIR* dir;
	struct dirent *dir_entry;
	int inside_cur_or_new = 0;
	int i, rc;

	// skip excluded paths
	for(i = 0; i < n_excludes; i++){
		if ( (rc = fnmatch(excludes[i], path, 0)) == 0 ) {
			VERBOSE(analyze_dir,
				"skipping '%s' because excluded by pattern '%s'\n",
				path, excludes[i]);
			return;
		}
		if ( rc != FNM_NOMATCH ){
			ERROR(fnmatch,"processing pattern '%s': %s",excludes[i],
				strerror(errno))
		}
	}

	// detect if inside cur/ or new/
#ifdef __GLIBC__
	const char* bname = basename(path);
#else
	gchar* bname = g_path_get_basename(path);
#endif
	if ( !strcmp(bname,"cur") || !strcmp(bname,"new") ) {
		inside_cur_or_new = 1;
		if ( only_list_subfolders ) {
				fprintf(stdout, "%s\n", path);
				return;
		}
	}
#ifndef __GLIBC__
	g_free(bname);
#endif

	dir = opendir(path);
	if (dir == NULL) ERROR(opendir, "Unable to open directory '%s'\n", path);

	while ( (dir_entry = readdir(dir)) != NULL) {
		if (DT_REG == dir_entry->d_type) {
			if ( inside_cur_or_new && !only_list_subfolders ) {
				analyze_file(path,dir_entry->d_name);
			} else {
				VERBOSE(analyze_dir,"skipping '%s/%s', outside maildir\n",
					path,dir_entry->d_name);
			}
		} else if ((DT_DIR == dir_entry->d_type ||
					DT_LNK == dir_entry->d_type) &&
				strcmp(dir_entry->d_name,"tmp") &&
				strcmp(dir_entry->d_name,".") &&
				strcmp(dir_entry->d_name,"..")){
			int len = strlen(path) + 1 + strlen(dir_entry->d_name) + 1;
			char * newdir = malloc(len);
			snprintf(newdir,len,"%s/%s",path,dir_entry->d_name);
			analyze_dir(newdir);
			free(newdir);
		}
	}
	closedir(dir);
}

STATIC void analyze_dirs(char* paths[], int no){
	int i;
	for(i=0; i<no; i++){
		// we remove a trailing '/' if any 
		char *data = strdup(txtURL(paths[i],tmpbuff_5));
		if (data[strlen(data)-1] == '/') data[strlen(data)-1] = '\0';
		analyze_dir(data);
		free(data);
	}
}

// at the end of the analysis phase, look at the mails data structure to
// identify mails that are not available anymore and should be removed
STATIC void generate_deletions(){
	size_t m;

	for(m=1; m < mailno; m++){
		if (mail(m)->seen == NOT_SEEN) 
			COMMAND_DELETE(m);
		else 
			VERBOSE(seen,"STATUS OF %s %s %s IS %s\n",
				mail_name(m),txtsha(mail(m)->hsha,tmpbuff_1),
				txtsha(mail(m)->bsha,tmpbuff_2),strsight(mail(m)->seen));
	}
}

STATIC void extra_sha_file(const char* file, int suddenly_flush) {    
	unsigned char *addr,*next;
	int fd, header_found;
	struct stat sb;
	gchar* sha1;

	fd = open(file, O_RDONLY | O_NOATIME);
	if (fd == -1) ERROR(open,"unable to open file '%s'\n",file);

	if (fstat(fd, &sb) == -1) ERROR(fstat,"unable to stat file '%s'\n",file);
	if (! S_ISREG(sb.st_mode)) {
		ERROR(fstat,"not a regular file '%s'\n",file);
	}

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

	if (suddenly_flush) fflush(stdout);
}

// ============================ main =====================================

#define OPT_MAX_MAILNO 300
#define OPT_DB_FILE    301
#define OPT_EXCLUDE    302

// command line options
STATIC struct option long_options[] = {
	{"max-mailno", required_argument, NULL, OPT_MAX_MAILNO},
	{"db-file"   , required_argument, NULL, OPT_DB_FILE},
	{"exclude"   , required_argument, NULL, OPT_EXCLUDE},
	{"list"      , no_argument      , NULL, 'l'},
	{"symlink"   , no_argument      , NULL, 's'},
	{"verbose"   , no_argument      , NULL, 'v'},
	{"dry-run"   , no_argument      , NULL, 'd'},
	{"help"      , no_argument      , NULL, 'h'},
	{NULL        , no_argument      , NULL, 0},
};

// command line options documentation
STATIC const char* long_options_doc[] = {
	" number Estimation of max mail message number (defaults to the"
				"\n                      "
				"number of messages in the db-file + 1000 or "
				tostring(DEFAULT_MAIL_NUMBER)
				"\n                      "
				"if there is no db-file). You may want to decrease it"
				"\n                      "
				"for the first run on small systems. It is anyway"
				"\n                      "
				"increased automatically when needed",
	"path      Name of the cache for the endpoint (default db.txt)",
	"glob      Exclude paths matching the given glob expression",
			"Only list subfolders (short -l)",
			"Symbolic Link generation mode (short -s)",
			"Increase program verbosity (printed on stderr, short -v)",
			"Do not generate a new db file (short -d)",
			"This help screen",
			NULL
};

// print help and bail out
STATIC void help(char* argv0){
	int i;
	char *bname = g_path_get_basename(argv0);

	fprintf(stdout,"\nUsage: %s [options] (dirs...|fifo)\n",bname);
	for (i=0;long_options[i].name != NULL;i++) {
		if ( long_options[i].has_arg == required_argument )
			fprintf(stdout,"  --%-8s%s\n",
				long_options[i].name,long_options_doc[i]);
		else
			fprintf(stdout,"  --%-18s%s\n",
				long_options[i].name,long_options_doc[i]);
	}
	fprintf(stdout,"\n\
If paths is a single fifo, %s reads from it file names and outputs the\n\
sha1 of their header and body separated by space.\n\n\
If paths is a list of directories, %s outputs a list of actions a client\n\
has to perform to syncronize a copy of the same maildirs. This set of actions\n\
is relative to a previous status of the maildir stored in the db file.\n\
The input directories are traversed recursively, and every file encountered\n\
inside directories named cur/ and new/ is a potential mail message (if it\n\
contains no \\n\\n it is skipped).\n\n\
Every client must use a different db-file, and the db-file is strictly\n\
related with the set of directories given as arguments, and should not\n\
be used with a different directory set. Adding items to the directory\n\
set is safe, while removing them may not do what you want (delete actions\n\
are generated).\n", bname, bname);
	fprintf(stdout,
		"\nVersion %s, © 2009 Enrico Tassi, released under GPLv3, \
no waranties\n\n",SMD_CONF_VERSION);
}

int main(int argc, char *argv[]) {
	char *data;
	char *dbfile="db.txt";
	unsigned long int mailno = 0;
	unsigned int filenamelen = DEFAULT_FILENAME_LEN;
	struct stat sb;
	int c = 0;
	int option_index = 0;
	time_t bigbang;

	glib_check_version(2,16,0);
	g_assert(MAIL(NULL) == 0);
	g_assert(GPTR(0) == NULL);
	g_assert(MAIL(GPTR(1)) == 1);

	for(;;) {
		c = getopt_long(argc, argv, "vhdls", long_options, &option_index);
		if (c == -1) break; // no more args
		switch (c) {
			case OPT_MAX_MAILNO:
				mailno = strtoul(optarg,NULL,10);
			break;
			case OPT_DB_FILE:
				dbfile = strdup(optarg);
			break;
			case OPT_EXCLUDE:
				excludes = realloc(excludes, sizeof(char*) * (n_excludes + 1));
				excludes[n_excludes] = strdup(txtURL(optarg,tmpbuff_5));
				n_excludes++;
			break;
			case 'v':
				verbose = 1;
			break;
			case 'd':
				dry_run = 1;
			break;
			case 'l':
				only_list_subfolders = 1;
			break;
			case 's':
				only_generate_symlinks = 1;
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
	data = strdup(txtURL(argv[optind],tmpbuff_5));

	// check if data is a directory or a regular file
	c = stat(data, &sb);
	if (c != 0) ERROR(stat,"unable to stat %s\n",data);
	
	if ( S_ISFIFO(sb.st_mode) && argc - optind == 1){
		FILE *in = fopen(data,"r");
		if (in == NULL) {
			ERROR(fopen,"unable to open fifo %s\n",data);
			exit(EXIT_FAILURE);
		}
		if ( only_generate_symlinks ) {
			/* symlink */
			char src_name[MAX_EMAIL_NAME_LEN];
			char tgt_name[MAX_EMAIL_NAME_LEN];
			while (!feof(in)) {
				if(fgets(src_name,MAX_EMAIL_NAME_LEN,in) != NULL &&
				   fgets(tgt_name,MAX_EMAIL_NAME_LEN,in) != NULL) {
					size_t src_len = strlen(src_name);
					size_t tgt_len = strlen(tgt_name);
					if (src_len > 0 && src_name[src_len-1] == '\n')
						src_name[src_len-1]='\0';
					if (tgt_len > 0 && tgt_name[tgt_len-1] == '\n')
						tgt_name[tgt_len-1]='\0';
					gchar* dir_tgt = g_path_get_dirname(tgt_name);
					g_mkdir_with_parents(dir_tgt, 0770);
					if ( symlink(src_name, tgt_name) != 0 ){
						ERROR(symlink,"unable to symlink %s to %s: %s\n",
							src_name, tgt_name, strerror(errno));
						exit(EXIT_FAILURE);
					}
					g_free(dir_tgt);
				}
			}
		} else {
			/* sha1 */
			while (!feof(in)) {
				char name[MAX_EMAIL_NAME_LEN];
				if(fgets(name,MAX_EMAIL_NAME_LEN,in) != NULL){
					size_t len = strlen(name);
					if (len > 0 && name[len-1] == '\n') name[len-1]='\0';
					extra_sha_file(name,1);
				}
			}
		}
		exit(EXIT_SUCCESS);
	} else if ( ! S_ISDIR(sb.st_mode) ) {
		ERROR(stat, "given path is not a fifo nor a directory: %s\n",data);
	}
	free(data);
	
	// regular case, hash the content of maildirs rooted in the 
	// list of directories specified at command line
	ASSERT_ALL_ARE(directory, &argv[optind], argc - optind);

	if ( only_list_subfolders ) {
		analyze_dirs(&argv[optind], argc - optind);
		exit(EXIT_SUCCESS);
	}

	// allocate memory
	setup_globals(dbfile, mailno, filenamelen);

	load_db(dbfile);

	bigbang = time(NULL);
	analyze_dirs(&argv[optind], argc - optind);

	generate_deletions();

	if (!dry_run) save_db(dbfile, bigbang);

	exit(EXIT_SUCCESS);
}

// vim:set ts=4:
