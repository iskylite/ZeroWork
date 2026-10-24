/* Optional desktop settings: bounded portal read, then native GSettings, then
 * gtk settings.ini. Called only at creation, never inside a native hit query. */
static int chrome_setting_string(const char *schema_name,const char *key,char *out,size_t capacity) {
    int ok=0;static void *library; if(!library)library=dlopen("libgio-2.0.so.0",RTLD_NOW|RTLD_LOCAL);void *lib=library;if(!lib)return 0;
    void *(*bus_get)(int,void *,void **)=dlsym(lib,"g_bus_get_sync");
    void *(*call)(void *,const char *,const char *,const char *,const char *,void *,const void *,int,int,void *,void **)=dlsym(lib,"g_dbus_connection_call_sync");
    void *(*variant_new)(const char *,...)=dlsym(lib,"g_variant_new");
    void *(*child)(void *,size_t)=dlsym(lib,"g_variant_get_child_value");
    void *(*unbox)(void *)=dlsym(lib,"g_variant_get_variant");
    char (*classify)(void *)=dlsym(lib,"g_variant_classify");
    const char *(*string)(void *,size_t *)=dlsym(lib,"g_variant_get_string");
    void (*v_unref)(void *)=dlsym(lib,"g_variant_unref");
    void (*o_unref)(void *)=dlsym(lib,"g_object_unref");
    if(bus_get&&call&&variant_new&&child&&unbox&&classify&&string&&v_unref&&o_unref){
        void *bus=bus_get(2,NULL,NULL);
        if(bus){void *reply=call(bus,"org.freedesktop.portal.Desktop","/org/freedesktop/portal/desktop","org.freedesktop.portal.Settings","Read",variant_new("(ss)",schema_name,key),NULL,0,150,NULL,NULL);
            if(reply){void *value=child(reply,0);for(int i=0;value&&classify(value)=='v'&&i<4;++i){void *next=unbox(value);v_unref(value);value=next;}
                if(value&&classify(value)=='s'){const char *text=string(value,NULL);if(text&&strlen(text)<capacity){strcpy(out,text);ok=1;}}
                if(value)v_unref(value);v_unref(reply);}
            o_unref(bus);}
    }
    void *(*source_default)(void)=dlsym(lib,"g_settings_schema_source_get_default");
    void *(*schema_lookup)(void *,const char *,int)=dlsym(lib,"g_settings_schema_source_lookup");
    int (*has_key)(void *,const char *)=dlsym(lib,"g_settings_schema_has_key");
    void (*schema_unref)(void *)=dlsym(lib,"g_settings_schema_unref");
    void *(*settings_new)(void *,void *,const char *)=dlsym(lib,"g_settings_new_full");
    char *(*get_string)(void *,const char *)=dlsym(lib,"g_settings_get_string");
    void (*gfree)(void *)=dlsym(lib,"g_free");
    const char *desktop=getenv("XDG_CURRENT_DESKTOP");
    if(!ok&&desktop&&strstr(desktop,"GNOME")&&source_default&&schema_lookup&&has_key&&schema_unref&&settings_new&&get_string&&o_unref&&gfree){
        void *source=source_default(),*schema=source?schema_lookup(source,schema_name,1):NULL;
        if(schema){if(has_key(schema,key)){void *settings=settings_new(schema,NULL,NULL);if(settings){char *text=get_string(settings,key);if(text&&strlen(text)<capacity){strcpy(out,text);ok=1;}if(text)gfree(text);o_unref(settings);}}schema_unref(schema);}
    }
    /* GLib type registration retains function pointers: keep the module for process lifetime. */
    return ok;
}
static void chrome_settings_read(ZenitWaylandWindow *w) {
    strcpy(w->chrome_button_layout,":minimize,maximize,close");strcpy(w->chrome_double_click,"toggle-maximize");strcpy(w->chrome_middle_click,"none");
    const char *desktop=getenv("XDG_CURRENT_DESKTOP");w->chrome_appearance=desktop&&strstr(desktop,"KDE")?4:3;
    if(!chrome_setting_string("org.gnome.desktop.wm.preferences","button-layout",w->chrome_button_layout,sizeof(w->chrome_button_layout))){
        char path[4096];const char *config=getenv("XDG_CONFIG_HOME"),*home=getenv("HOME");
        int n=config&&*config?snprintf(path,sizeof(path),"%s/gtk-3.0/settings.ini",config):home?snprintf(path,sizeof(path),"%s/.config/gtk-3.0/settings.ini",home):-1;
        FILE *f=n>0&&(size_t)n<sizeof(path)?fopen(path,"r"):NULL;
        if(f){char line[512];int section=0;while(fgets(line,sizeof(line),f)){char *p=line;while(*p==' '||*p=='\t')++p;
            if(*p=='['){section=strncmp(p,"[Settings]",10)==0;continue;}
            if(section&&strncmp(p,"gtk-decoration-layout",21)==0){p+=21;while(*p==' '||*p=='\t')++p;if(*p!='=')continue;++p;while(*p==' '||*p=='\t')++p;size_t len=strcspn(p,"\r\n");if(len<sizeof(w->chrome_button_layout)){memcpy(w->chrome_button_layout,p,len);w->chrome_button_layout[len]=0;}}
        }fclose(f);}
    }
    chrome_setting_string("org.gnome.desktop.wm.preferences","action-double-click-titlebar",w->chrome_double_click,sizeof(w->chrome_double_click));
    chrome_setting_string("org.gnome.desktop.wm.preferences","action-middle-click-titlebar",w->chrome_middle_click,sizeof(w->chrome_middle_click));
}
static void chrome_button_layout(const char *text,uint32_t out[6]) {
    memset(out,0,6*sizeof(*out));const char *colon=strchr(text,':');if(!colon||strchr(colon+1,':')){out[3]=1;out[4]=2;out[5]=3;return;}
    unsigned seen=0;for(unsigned side=0;side<2;++side){const char *p=side?colon+1:text,*end=side?text+strlen(text):colon;unsigned count=0;
        while(p<end){const char *next=memchr(p,',',(size_t)(end-p));if(!next)next=end;while(p<next&&(*p==' '||*p=='\t'))++p;const char *last=next;while(last>p&&(last[-1]==' '||last[-1]=='\t'))--last;
            size_t n=(size_t)(last-p);unsigned c=n==8&&!memcmp(p,"minimize",8)?1:n==8&&!memcmp(p,"maximize",8)?2:n==5&&!memcmp(p,"close",5)?3:0;
            if(c&&!(seen&(1u<<c))&&count<3){out[side*3+count++]=c;seen|=1u<<c;}p=next<end?next+1:end;}
    }
}
