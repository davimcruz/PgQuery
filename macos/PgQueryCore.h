#include <stdbool.h>

void pg_connect(const char *value);
void pg_query(const char *value);
void pg_select_table(const char *value);
char * _Nullable pg_poll(void);
void pg_string_free(char * _Nullable value);
