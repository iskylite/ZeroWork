#ifndef ZENIT_AUTOMATION_ENVIRONMENT_H
#define ZENIT_AUTOMATION_ENVIRONMENT_H
#include <stdlib.h>
/* Test instrumentation never accepts process overrides in a formal App. */
static inline const char *zenitAutomationEnvironment(const char *name) {
#if defined(ZENIT_AUTOMATION_ENVIRONMENT) && ZENIT_AUTOMATION_ENVIRONMENT
    return getenv(name);
#else
    (void)name;
    return NULL;
#endif
}
#endif
