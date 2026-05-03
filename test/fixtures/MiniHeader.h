#ifndef MINI_HEADER_H
#define MINI_HEADER_H

#include <stdint.h>

typedef int32_t MiniStatus;

typedef struct MiniClient *MiniClientRef;

typedef enum {
  kMiniErrorNone = 0,
  kMiniErrorBadInput = -1
} MiniError;

extern const char *kMiniDefaultName;

MiniStatus MiniCreate(const char *name, MiniClientRef *outClient);
MiniStatus MiniDispose(MiniClientRef client);

#endif
