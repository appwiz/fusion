{.used.}

import kernel/debugcon

var
  heap*: array[2*1024*1024, byte]
  heapBumpPtr*: int = cast[int](addr heap[0])
  heapMaxPtr*: int = cast[int](addr heap[0]) + heap.high

proc malloc*(size: csize_t): pointer {.exportc.} =
  if heapBumpPtr + size.int > heapMaxPtr:
    debugln "Out of memory"
    # return nil
    quit()

  result = cast[pointer](heapBumpPtr)
  inc heapBumpPtr, size.int

proc calloc*(num: csize_t, size: csize_t): pointer {.exportc.} =
  result = malloc(size * num)

proc realloc*(p: pointer, new_size: csize_t): pointer {.exportc.} =
  result = malloc(new_size)
  copyMem(result, p, new_size)
  free(p)

proc free*(p: pointer) {.exportc.} =
  discard
