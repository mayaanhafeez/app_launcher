#include "../lua.h"
#include "../lauxlib.h"
#include "../lualib.h"

static const int CLUA_REGISTRYINDEX = LUA_REGISTRYINDEX;

static inline int clua_error(lua_State *L, const char *message) {
  lua_pushstring(L, message);
  return lua_error(L);
}
