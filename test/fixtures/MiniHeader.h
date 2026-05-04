#ifndef MINI_HEADER_H
#define MINI_HEADER_H

#include <stdint.h>

typedef int32_t MiniStatus;

typedef struct MiniClient *MiniClientRef;

typedef void (*MiniCallback)(MiniStatus status, void *userData);

typedef enum {
  kMiniErrorNone = 0,
  kMiniErrorBadInput = -1
} MiniError;

extern const char *kMiniDefaultName;

MiniStatus MiniCreate(const char *name, MiniClientRef *outClient);
MiniStatus MiniDispose(MiniClientRef client);

typedef uint32_t MiniNodeRef;

double MiniGetRatio(MiniClientRef client);
_Bool MiniIsActive(MiniClientRef client, _Bool checkPower);
MiniStatus MiniWithCallback(MiniCallback cb, void *userData);
MiniStatus MiniMakeNode(MiniClientRef client, MiniNodeRef *outNode);

#endif
