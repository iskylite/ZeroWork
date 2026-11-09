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
typedef struct {zw_sink sink;void *ctx;zw_cancel cancel;void *cancel_ctx;char *session;char *type;char *challenge;int stopped;size_t total;long long *deadline;int timedout;int acknowledged;} web_ctx;
static size_t body_cb(char *b,size_t s,size_t n,void *raw){web_ctx *c=raw;size_t len=s*n;c->total+=len;if(c->total>32U*1024U*1024U)return 0;long long before=now_ms();int r=c->sink(c->ctx,(unsigned char*)b,len);*c->deadline+=now_ms()-before;if(r==2){c->acknowledged=1;return len;}if(r){c->stopped=r;return 0;}return len;}
static size_t header_cb(char *b,size_t s,size_t n,void *raw){web_ctx *c=raw;size_t len=s*n;char *dest=NULL;size_t cap=0,offset=0;if(len>15&&!strncasecmp(b,"Mcp-Session-Id:",15)){dest=c->session;cap=512;offset=15;}if(len>13&&!strncasecmp(b,"Content-Type:",13)){dest=c->type;cap=128;offset=13;}if(len>17&&!strncasecmp(b,"WWW-Authenticate:",17)){dest=c->challenge;cap=8192;offset=17;}if(dest){while(offset<len&&(b[offset]==' '||b[offset]=='\t'))offset++;size_t end=len;while(end>offset&&(b[end-1]=='\r'||b[end-1]=='\n'||b[end-1]==' '))end--;if(end-offset>=cap)return 0;for(size_t i=offset;i<end;i++)if((unsigned char)b[i]<32||b[i]==127)return 0;memcpy(dest,b+offset,end-offset);dest[end-offset]=0;}return len;}
static int progress_cb(void *raw,curl_off_t a,curl_off_t b,curl_off_t c,curl_off_t d){(void)a;(void)b;(void)c;(void)d;web_ctx *x=raw;if(now_ms()>=*x->deadline){x->timedout=1;return 1;}return x->cancel&&x->cancel(x->cancel_ctx);}
int zw_mcp_http(const char *url,const char *method,const char *const *headers,size_t count,const unsigned char *body,size_t size,unsigned timeout,zw_sink sink,void *ctx,zw_cancel cancel,void *cancel_ctx,char *session,char *type,char *challenge,unsigned *status,zw_sink listener,void *listener_ctx,char *listener_type,const unsigned char *listener_body,size_t listener_size){
 pthread_once(&curl_once,init_curl);CURL *h=curl_easy_init();if(!h)return -1;long long deadline=now_ms()+timeout;web_ctx c={sink,ctx,cancel,cancel_ctx,session,type,challenge,0,0,&deadline,0};struct curl_slist *list=NULL;
 for(size_t i=0;i<count;i++){struct curl_slist *next=curl_slist_append(list,headers[i]);if(!next){curl_slist_free_all(list);curl_easy_cleanup(h);return -1;}list=next;}
 curl_easy_setopt(h,CURLOPT_URL,url);curl_easy_setopt(h,CURLOPT_CUSTOMREQUEST,method);curl_easy_setopt(h,CURLOPT_HTTPHEADER,list);curl_easy_setopt(h,CURLOPT_POSTFIELDS,body);curl_easy_setopt(h,CURLOPT_POSTFIELDSIZE_LARGE,(curl_off_t)size);
 curl_easy_setopt(h,CURLOPT_PROTOCOLS,CURLPROTO_HTTP|CURLPROTO_HTTPS);curl_easy_setopt(h,CURLOPT_FOLLOWLOCATION,0L);curl_easy_setopt(h,CURLOPT_TIMEOUT_MS,0L);curl_easy_setopt(h,CURLOPT_CONNECTTIMEOUT_MS,(long)timeout);curl_easy_setopt(h,CURLOPT_NOSIGNAL,1L);
 curl_easy_setopt(h,CURLOPT_WRITEFUNCTION,body_cb);curl_easy_setopt(h,CURLOPT_WRITEDATA,&c);curl_easy_setopt(h,CURLOPT_HEADERFUNCTION,header_cb);curl_easy_setopt(h,CURLOPT_HEADERDATA,&c);curl_easy_setopt(h,CURLOPT_NOPROGRESS,0L);curl_easy_setopt(h,CURLOPT_XFERINFOFUNCTION,progress_cb);curl_easy_setopt(h,CURLOPT_XFERINFODATA,&c);
 CURLcode r=CURLE_OK;
 if(listener){
  CURL *get=curl_easy_init();CURLM *multi=curl_multi_init();
  if(!get||!multi){if(get)curl_easy_cleanup(get);if(multi)curl_multi_cleanup(multi);curl_slist_free_all(list);curl_easy_cleanup(h);return -1;}
  char get_session[512]={0},get_challenge[8192]={0};web_ctx g={listener,listener_ctx,cancel,cancel_ctx,get_session,listener_type,get_challenge,0,0,&deadline,0};
  struct curl_slist *listen_headers=NULL;
  if(listener_body){
   for(size_t i=0;i<count;i++){if(!strncasecmp(headers[i],"Mcp-Method:",11)||!strncasecmp(headers[i],"Mcp-Name:",9)||!strncasecmp(headers[i],"Mcp-Param-",10))continue;listen_headers=curl_slist_append(listen_headers,headers[i]);}
   listen_headers=curl_slist_append(listen_headers,"Mcp-Method: subscriptions/listen");
   curl_easy_setopt(get,CURLOPT_HTTPHEADER,listen_headers);curl_easy_setopt(get,CURLOPT_POSTFIELDS,listener_body);curl_easy_setopt(get,CURLOPT_POSTFIELDSIZE_LARGE,(curl_off_t)listener_size);
  }else {curl_easy_setopt(get,CURLOPT_HTTPHEADER,list);curl_easy_setopt(get,CURLOPT_HTTPGET,1L);}
  curl_easy_setopt(get,CURLOPT_URL,url);
  curl_easy_setopt(get,CURLOPT_PROTOCOLS,CURLPROTO_HTTP|CURLPROTO_HTTPS);curl_easy_setopt(get,CURLOPT_FOLLOWLOCATION,0L);curl_easy_setopt(get,CURLOPT_NOSIGNAL,1L);curl_easy_setopt(get,CURLOPT_CONNECTTIMEOUT_MS,(long)timeout);
  curl_easy_setopt(get,CURLOPT_WRITEFUNCTION,body_cb);curl_easy_setopt(get,CURLOPT_WRITEDATA,&g);curl_easy_setopt(get,CURLOPT_HEADERFUNCTION,header_cb);curl_easy_setopt(get,CURLOPT_HEADERDATA,&g);curl_easy_setopt(get,CURLOPT_NOPROGRESS,0L);curl_easy_setopt(get,CURLOPT_XFERINFOFUNCTION,progress_cb);curl_easy_setopt(get,CURLOPT_XFERINFODATA,&g);
  curl_multi_add_handle(multi,get);int main_added=listener_body?0:1;if(main_added)curl_multi_add_handle(multi,h);int running=0,done=0;
  while(!done){
   CURLMcode mr=curl_multi_perform(multi,&running);if(mr!=CURLM_OK){r=CURLE_RECV_ERROR;break;}
   int pending;CURLMsg *message;while((message=curl_multi_info_read(multi,&pending))){if(message->msg==CURLMSG_DONE&&message->easy_handle==h){r=message->data.result;done=1;}else if(message->msg==CURLMSG_DONE&&message->easy_handle==get&&listener_body&&!g.acknowledged){r=CURLE_RECV_ERROR;done=1;}}
   if(!main_added&&g.acknowledged){curl_multi_add_handle(multi,h);main_added=1;}
   if(done)break;if(g.stopped<0){r=CURLE_WRITE_ERROR;break;}if(cancel&&cancel(cancel_ctx)){r=CURLE_ABORTED_BY_CALLBACK;break;}
   if(now_ms()>=deadline){c.timedout=1;r=CURLE_OPERATION_TIMEDOUT;break;}
   curl_multi_poll(multi,NULL,0,20,NULL);
  }
  if(main_added)curl_multi_remove_handle(multi,h);curl_multi_remove_handle(multi,get);curl_easy_cleanup(get);curl_slist_free_all(listen_headers);curl_multi_cleanup(multi);
 }else r=curl_easy_perform(h);
 long code=0;curl_easy_getinfo(h,CURLINFO_RESPONSE_CODE,&code);*status=(unsigned)code;curl_slist_free_all(list);curl_easy_cleanup(h);
 if(cancel&&cancel(cancel_ctx))return -3;if(c.stopped==1)return 0;if(r==CURLE_OPERATION_TIMEDOUT||c.timedout)return -2;return r==CURLE_OK?0:-1;
}

/* JSON Schema validation is provided by pinned Ajv in an isolated system
 * JavaScriptCore context. No Node runtime, host objects or network APIs. */
#include <JavaScriptCore/JavaScript.h>
#include <dlfcn.h>
static bool zw_schema_timeout(JSContextRef ctx,void *data){(void)ctx;(void)data;return true;}
typedef void (*zw_js_limit)(JSContextGroupRef,double,bool (*)(JSContextRef,void *),void *);
void *zw_mcp_schema_create(const char *bundle) {
    JSGlobalContextRef ctx=JSGlobalContextCreate(NULL);
    if(!ctx)return NULL;
    JSStringRef script=JSStringCreateWithUTF8CString(bundle);
    JSValueRef exception=NULL;
    JSEvaluateScript(ctx,script,NULL,NULL,0,&exception);
    JSStringRelease(script);
    if(exception){JSGlobalContextRelease(ctx);return NULL;}
    return (void *)ctx;
}
void zw_mcp_schema_close(void *raw){if(raw)JSGlobalContextRelease((JSGlobalContextRef)raw);}
int zw_mcp_schema_validate(void *raw,const char *schema,const char *instance) {
    JSContextRef ctx=(JSContextRef)raw;
    JSStringRef key=JSStringCreateWithUTF8CString("zwMcpSchema");
    JSValueRef exception=NULL;
    JSValueRef fn=JSObjectGetProperty(ctx,JSContextGetGlobalObject(ctx),key,&exception);
    JSStringRelease(key);
    if(exception||!JSValueIsObject(ctx,fn))return -1;
    JSStringRef s=JSStringCreateWithUTF8CString(schema);
    JSStringRef v=instance?JSStringCreateWithUTF8CString(instance):NULL;
    JSValueRef args[2]={JSValueMakeString(ctx,s),v?JSValueMakeString(ctx,v):JSValueMakeNull(ctx)};
    zw_js_limit limit=(zw_js_limit)dlsym(RTLD_DEFAULT,"JSContextGroupSetExecutionTimeLimit");
    if(limit)limit(JSContextGetGroup(ctx),1.0,zw_schema_timeout,NULL);
    JSValueRef result=JSObjectCallAsFunction(ctx,JSValueToObject(ctx,fn,NULL),NULL,2,args,&exception);
    JSStringRelease(s);if(v)JSStringRelease(v);
    if(exception||!result||!JSValueIsNumber(ctx,result))return -1;
    return (int)JSValueToNumber(ctx,result,NULL);
}

/* OAuth redirects are accepted only on an ephemeral IPv4 loopback socket. */
#include <sys/socket.h>
#include <netinet/in.h>
int zw_mcp_callback_start(unsigned *port) {
 int fd=socket(AF_INET,SOCK_STREAM,0);if(fd<0)return -1;
 fcntl(fd,F_SETFD,FD_CLOEXEC);fcntl(fd,F_SETFL,O_NONBLOCK);
 struct sockaddr_in a={0};a.sin_family=AF_INET;a.sin_addr.s_addr=htonl(INADDR_LOOPBACK);a.sin_port=0;
 socklen_t n=sizeof a;if(bind(fd,(struct sockaddr*)&a,n)||listen(fd,4)||getsockname(fd,(struct sockaddr*)&a,&n)){close(fd);return -1;}
 *port=ntohs(a.sin_port);return fd;
}
void zw_mcp_callback_close(int fd){if(fd>=0)close(fd);}
int zw_mcp_callback_wait(int fd,char *target,size_t capacity,unsigned timeout,zw_cancel cancel,void *ctx){
 long long end=now_ms()+timeout;
 for(;;){if(cancel&&cancel(ctx))return -3;if(now_ms()>end)return -2;
  struct pollfd p={fd,POLLIN,0};if(poll(&p,1,20)<=0)continue;
  int c=accept(fd,NULL,NULL);if(c<0)continue;
  fcntl(c,F_SETNOSIGPIPE,1);fcntl(c,F_SETFL,O_NONBLOCK);
  char b[16384];size_t used=0;long long header_end=now_ms()+2000;
  while(used<sizeof b-1&&now_ms()<header_end){ssize_t k=read(c,b+used,sizeof b-1-used);if(k>0){used+=(size_t)k;b[used]=0;if(strstr(b,"\r\n\r\n"))break;}else if(k==0)break;else {struct pollfd q={c,POLLIN,0};poll(&q,1,20);}if(cancel&&cancel(ctx)){close(c);return -3;}}
  b[used]=0;char *space=used>4?strchr(b+4,' '):NULL;
  int ok=space&&!strncmp(b,"GET /callback?",14)&&(size_t)(space-b-4)<capacity;
  const char *reply=ok?"HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nConnection: close\r\nCache-Control: no-store\r\n\r\nAuthorization response received. Return to ZeroWork.":"HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\nInvalid callback";
  (void)write(c,reply,strlen(reply));close(c);
  if(ok){size_t len=(size_t)(space-b-4);memcpy(target,b+4,len);target[len]=0;return 0;}
 }
}

/* Modern subscriptions carry notifications only. A dedicated reader queues
 * bytes; Zig consumes them on the task worker, never from this thread. */
#include <stdatomic.h>
typedef struct {
 pthread_t thread;pthread_mutex_t lock;_Atomic int stop;
 char *url,*body;char **headers;size_t count,size;unsigned timeout;
 unsigned char *bytes;size_t used,capacity;int done;
 char content_type[128];
} zw_mcp_subscription;
static int subscription_cancel(void *raw,curl_off_t a,curl_off_t b,curl_off_t c,curl_off_t d){
 (void)a;(void)b;(void)c;(void)d;return atomic_load(&((zw_mcp_subscription*)raw)->stop);
}
static size_t subscription_body(char *b,size_t size,size_t count,void *raw){
 zw_mcp_subscription *s=raw;size_t n=size*count;
 if(strncmp(s->content_type,"text/event-stream",17))return 0;
 pthread_mutex_lock(&s->lock);
 if(n>32U*1024U*1024U-s->used){pthread_mutex_unlock(&s->lock);return 0;}
 if(s->used+n>s->capacity){size_t cap=s->capacity?s->capacity:4096;while(cap<s->used+n)cap*=2;unsigned char *next=realloc(s->bytes,cap);if(!next){pthread_mutex_unlock(&s->lock);return 0;}s->bytes=next;s->capacity=cap;}
 memcpy(s->bytes+s->used,b,n);s->used+=n;pthread_mutex_unlock(&s->lock);return n;
}
static void *subscription_worker(void *raw){
 zw_mcp_subscription *s=raw;pthread_once(&curl_once,init_curl);CURL *h=curl_easy_init();struct curl_slist *headers=NULL;
 if(!h)goto done;
 for(size_t i=0;i<s->count;i++){struct curl_slist *next=curl_slist_append(headers,s->headers[i]);if(!next)goto cleanup;headers=next;}
 headers=curl_slist_append(headers,"Mcp-Method: subscriptions/listen");if(!headers)goto cleanup;
 char session[512]={0},challenge[8192]={0};long long deadline=now_ms()+86400000;web_ctx web={0};web.session=session;web.type=s->content_type;web.challenge=challenge;web.deadline=&deadline;
 curl_easy_setopt(h,CURLOPT_URL,s->url);curl_easy_setopt(h,CURLOPT_HTTPHEADER,headers);curl_easy_setopt(h,CURLOPT_POSTFIELDS,s->body);curl_easy_setopt(h,CURLOPT_POSTFIELDSIZE_LARGE,(curl_off_t)s->size);
 curl_easy_setopt(h,CURLOPT_PROTOCOLS,CURLPROTO_HTTP|CURLPROTO_HTTPS);curl_easy_setopt(h,CURLOPT_FOLLOWLOCATION,0L);curl_easy_setopt(h,CURLOPT_NOSIGNAL,1L);curl_easy_setopt(h,CURLOPT_CONNECTTIMEOUT_MS,(long)s->timeout);
 curl_easy_setopt(h,CURLOPT_WRITEFUNCTION,subscription_body);curl_easy_setopt(h,CURLOPT_WRITEDATA,s);curl_easy_setopt(h,CURLOPT_HEADERFUNCTION,header_cb);curl_easy_setopt(h,CURLOPT_HEADERDATA,&web);
 curl_easy_setopt(h,CURLOPT_NOPROGRESS,0L);curl_easy_setopt(h,CURLOPT_XFERINFOFUNCTION,subscription_cancel);curl_easy_setopt(h,CURLOPT_XFERINFODATA,s);
 (void)curl_easy_perform(h);
 cleanup:curl_slist_free_all(headers);curl_easy_cleanup(h);
 done:pthread_mutex_lock(&s->lock);s->done=1;pthread_mutex_unlock(&s->lock);return NULL;
}
static void subscription_free(zw_mcp_subscription *s){
 if(!s)return;for(size_t i=0;i<s->count;i++){if(s->headers[i]){memset(s->headers[i],0,strlen(s->headers[i]));free(s->headers[i]);}}free(s->headers);free(s->url);if(s->body){memset(s->body,0,s->size);free(s->body);}if(s->bytes){memset(s->bytes,0,s->capacity);free(s->bytes);}pthread_mutex_destroy(&s->lock);free(s);
}
void *zw_mcp_subscription_start(const char *url,const char *const *headers,size_t count,const unsigned char *body,size_t size,unsigned timeout){
 zw_mcp_subscription *s=calloc(1,sizeof(*s));if(!s)return NULL;pthread_mutex_init(&s->lock,NULL);atomic_init(&s->stop,0);s->url=strdup(url);s->body=malloc(size+1);s->headers=calloc(count,sizeof(char*));s->size=size;s->timeout=timeout;
 if(!s->url||!s->body||!s->headers){subscription_free(s);return NULL;}memcpy(s->body,body,size);s->body[size]=0;
 for(size_t i=0;i<count;i++){if(!strncasecmp(headers[i],"Mcp-Method:",11)||!strncasecmp(headers[i],"Mcp-Name:",9)||!strncasecmp(headers[i],"Mcp-Param-",10))continue;char *value=strdup(headers[i]);if(!value){subscription_free(s);return NULL;}s->headers[s->count++]=value;}
 if(pthread_create(&s->thread,NULL,subscription_worker,s)){subscription_free(s);return NULL;}return s;
}
int zw_mcp_subscription_read(void *raw,unsigned char *out,size_t capacity,unsigned timeout,zw_cancel cancel,void *ctx){
 zw_mcp_subscription *s=raw;long long until=now_ms()+timeout;
 for(;;){if(cancel&&cancel(ctx))return -3;pthread_mutex_lock(&s->lock);if(s->used){size_t n=s->used<capacity?s->used:capacity;memcpy(out,s->bytes,n);memmove(s->bytes,s->bytes+n,s->used-n);s->used-=n;pthread_mutex_unlock(&s->lock);return (int)n;}int done=s->done;pthread_mutex_unlock(&s->lock);if(done)return -1;if(now_ms()>=until)return -2;struct timespec pause={0,5000000};nanosleep(&pause,NULL);}
}
void zw_mcp_subscription_close(void *raw){if(!raw)return;zw_mcp_subscription *s=raw;atomic_store(&s->stop,1);pthread_join(s->thread,NULL);subscription_free(s);}
