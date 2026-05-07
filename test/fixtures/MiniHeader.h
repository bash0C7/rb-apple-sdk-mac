#ifndef MINI_HEADER_H
#define MINI_HEADER_H

#include <stdint.h>
#include <stdbool.h>

typedef int32_t MiniStatus;

typedef struct MiniClient *MiniClientRef;

typedef void (*MiniCallback)(MiniStatus status, void *userData);

typedef enum {
  kMiniErrorNone = 0,
  kMiniErrorBadInput = -1
} MiniError;

extern const char *kMiniDefaultName;

/** Creates a new Mini client.
 * @param name  optional client name, may be NULL
 * @param outClient receives the newly created client handle
 * @return kMiniErrorNone on success
 */
MiniStatus MiniCreate(const char *name, MiniClientRef *outClient);

/// Disposes the client and releases all resources.
MiniStatus MiniDispose(MiniClientRef client);

typedef uint32_t MiniNodeRef;

double MiniGetRatio(MiniClientRef client);
bool MiniIsActive(MiniClientRef client, bool checkPower);
MiniStatus MiniWithCallback(MiniCallback cb, void *userData);
MiniStatus MiniMakeNode(MiniClientRef client, MiniNodeRef *outNode);

#endif
