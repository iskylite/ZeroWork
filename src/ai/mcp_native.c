#define _DARWIN_C_SOURCE
#include <spawn.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <sys/wait.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <errno.h>
#include <time.h>
#include <curl/curl.h>
#include <pthread.h>
static pthread_once_t curl_once=PTHREAD_ONCE_INIT;
static void init_curl(void){curl_global_init(CURL_GLOBAL_DEFAULT);}
typedef int (*zw_cancel)(void *);
typedef int (*zw_sink)(void *, const unsigned char *, size_t);
typedef struct { pid_t pid; int input,output,error; } zw_mcp;
static long long now_ms(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return (long long)t.tv_sec*1000+t.tv_nsec/1000000;}
void *zw_mcp_start(const char *program,char *const argv[],char *const env[],const char *cwd){
 int in[2]={-1,-1},out[2]={-1,-1},err[2]={-1,-1};zw_mcp *p=NULL;
 if(pipe(in)||pipe(out)||pipe(err))goto fail;
 posix_spawn_file_actions_t f;posix_spawnattr_t a;posix_spawn_file_actions_init(&f);posix_spawnattr_init(&a);
 posix_spawn_file_actions_adddup2(&f,in[0],0);posix_spawn_file_actions_adddup2(&f,out[1],1);posix_spawn_file_actions_adddup2(&f,err[1],2);
 if(cwd&&*cwd)posix_spawn_file_actions_addchdir_np(&f,cwd);
 posix_spawnattr_setflags(&a,POSIX_SPAWN_SETPGROUP|POSIX_SPAWN_CLOEXEC_DEFAULT);posix_spawnattr_setpgroup(&a,0);
 pid_t pid;int rc=posix_spawn(&pid,program,&f,&a,argv,env);posix_spawn_file_actions_destroy(&f);posix_spawnattr_destroy(&a);if(rc)goto fail;
 p=calloc(1,sizeof(*p));if(!p){kill(-pid,SIGKILL);waitpid(pid,NULL,0);goto fail;}
 close(in[0]);close(out[1]);close(err[1]);p->pid=pid;p->input=in[1];p->output=out[0];p->error=err[0];
 fcntl(p->input,F_SETFL,O_NONBLOCK);fcntl(p->output,F_SETFL,O_NONBLOCK);fcntl(p->error,F_SETFL,O_NONBLOCK);
 fcntl(p->input,F_SETFD,FD_CLOEXEC);fcntl(p->output,F_SETFD,FD_CLOEXEC);fcntl(p->error,F_SETFD,FD_CLOEXEC);
 int one=1;fcntl(p->input,F_SETNOSIGPIPE,one);return p;
 fail:for(int i=0;i<2;i++){if(in[i]>=0)close(in[i]);if(out[i]>=0)close(out[i]);if(err[i]>=0)close(err[i]);}return NULL;
}
static void drain(zw_mcp *p){char b[4096];for(int i=0;i<16;i++)if(read(p->error,b,sizeof b)<=0)break;}
int zw_mcp_write(void *raw,const unsigned char *b,size_t n,unsigned timeout,zw_cancel cancel,void *ctx){zw_mcp *p=raw;long long end=now_ms()+timeout;while(n){if(cancel&&cancel(ctx))return -3;if(now_ms()>=end)return -2;drain(p);ssize_t k=write(p->input,b,n);if(k>0){b+=k;n-=k;continue;}if(k<0&&errno!=EAGAIN&&errno!=EINTR)return -1;struct pollfd f={p->input,POLLOUT,0};poll(&f,1,10);}return 0;}
int zw_mcp_read(void *raw,unsigned char *b,size_t n,unsigned timeout,zw_cancel cancel,void *ctx){zw_mcp *p=raw;long long end=now_ms()+timeout;for(;;){if(cancel&&cancel(ctx))return -3;drain(p);ssize_t k=read(p->output,b,n);if(k>0)return (int)k;if(k==0)return -1;if(errno!=EAGAIN&&errno!=EINTR)return -1;if(now_ms()>=end)return -2;struct pollfd f={p->output,POLLIN,0};poll(&f,1,10);}}
void zw_mcp_close(void *raw){if(!raw)return;zw_mcp *p=raw;close(p->input);long long end=now_ms()+100;int status;while(waitpid(p->pid,&status,WNOHANG)==0&&now_ms()<end)usleep(5000);kill(-p->pid,SIGTERM);end=now_ms()+200;while(waitpid(p->pid,&status,WNOHANG)==0&&now_ms()<end)usleep(5000);kill(-p->pid,SIGKILL);while(waitpid(p->pid,&status,0)<0&&errno==EINTR){}close(p->output);close(p->error);free(p);}
typedef struct {zw_sink sink;void *ctx;zw_cancel cancel;void *cancel_ctx;char *session;char *type;int stopped;size_t total;} web_ctx;
static size_t body_cb(char *b,size_t s,size_t n,void *raw){web_ctx *c=raw;size_t len=s*n;c->total+=len;if(c->total>1024*1024)return 0;int r=c->sink(c->ctx,(unsigned char*)b,len);if(r){c->stopped=r;return 0;}return len;}
static size_t header_cb(char *b,size_t s,size_t n,void *raw){web_ctx *c=raw;size_t len=s*n;char *dest=NULL;size_t cap=0,offset=0;if(len>15&&!strncasecmp(b,"Mcp-Session-Id:",15)){dest=c->session;cap=512;offset=15;}if(len>13&&!strncasecmp(b,"Content-Type:",13)){dest=c->type;cap=128;offset=13;}if(dest){while(offset<len&&(b[offset]==' '||b[offset]=='\t'))offset++;size_t end=len;while(end>offset&&(b[end-1]=='\r'||b[end-1]=='\n'||b[end-1]==' '))end--;if(end-offset>=cap)return 0;for(size_t i=offset;i<end;i++)if((unsigned char)b[i]<32||b[i]==127)return 0;memcpy(dest,b+offset,end-offset);dest[end-offset]=0;}return len;}
static int progress_cb(void *raw,curl_off_t a,curl_off_t b,curl_off_t c,curl_off_t d){(void)a;(void)b;(void)c;(void)d;web_ctx *x=raw;return x->cancel&&x->cancel(x->cancel_ctx);}
int zw_mcp_http(const char *url,const char *method,const char *const *headers,size_t count,const unsigned char *body,size_t size,unsigned timeout,zw_sink sink,void *ctx,zw_cancel cancel,void *cancel_ctx,char *session,char *type,unsigned *status){
 pthread_once(&curl_once,init_curl);CURL *h=curl_easy_init();if(!h)return -1;web_ctx c={sink,ctx,cancel,cancel_ctx,session,type,0,0};struct curl_slist *list=NULL;
 for(size_t i=0;i<count;i++){struct curl_slist *next=curl_slist_append(list,headers[i]);if(!next){curl_slist_free_all(list);curl_easy_cleanup(h);return -1;}list=next;}
 curl_easy_setopt(h,CURLOPT_URL,url);curl_easy_setopt(h,CURLOPT_CUSTOMREQUEST,method);curl_easy_setopt(h,CURLOPT_HTTPHEADER,list);curl_easy_setopt(h,CURLOPT_POSTFIELDS,body);curl_easy_setopt(h,CURLOPT_POSTFIELDSIZE_LARGE,(curl_off_t)size);
 curl_easy_setopt(h,CURLOPT_PROTOCOLS,CURLPROTO_HTTP|CURLPROTO_HTTPS);curl_easy_setopt(h,CURLOPT_FOLLOWLOCATION,0L);curl_easy_setopt(h,CURLOPT_TIMEOUT_MS,(long)timeout);curl_easy_setopt(h,CURLOPT_CONNECTTIMEOUT_MS,(long)timeout);curl_easy_setopt(h,CURLOPT_NOSIGNAL,1L);
 curl_easy_setopt(h,CURLOPT_WRITEFUNCTION,body_cb);curl_easy_setopt(h,CURLOPT_WRITEDATA,&c);curl_easy_setopt(h,CURLOPT_HEADERFUNCTION,header_cb);curl_easy_setopt(h,CURLOPT_HEADERDATA,&c);curl_easy_setopt(h,CURLOPT_NOPROGRESS,0L);curl_easy_setopt(h,CURLOPT_XFERINFOFUNCTION,progress_cb);curl_easy_setopt(h,CURLOPT_XFERINFODATA,&c);
 CURLcode r=curl_easy_perform(h);long code=0;curl_easy_getinfo(h,CURLINFO_RESPONSE_CODE,&code);*status=(unsigned)code;curl_slist_free_all(list);curl_easy_cleanup(h);
 if(cancel&&cancel(cancel_ctx))return -3;if(c.stopped==1)return 0;if(r==CURLE_OPERATION_TIMEDOUT)return -2;return r==CURLE_OK?0:-1;
}
