// A Windows program for Wine under tso-arm (x86_64-w64-mingw32-gcc -O2 -o spsc.exe spsc.c): a ring buffer written
// for x86's memory order between two Win32 threads (CreateThread), plain stores for the data and the index, no
// fences; the reader checks every message. Only x86's order keeps it from seeing an index before the data it covers.
// Then a few things Windows programs do at start: the Win32 heap, a critical section, an event, the time.
//   spsc.exe [messages]   prints "spsc: N messages, W arrived wrong" and exits 1 if W > 0
#include <stdio.h>
#include <stdlib.h>
#include <windows.h>

#define SLOTS 1024
static volatile unsigned long long ring[SLOTS];
static volatile LONG64 head, tail;
static LONG64 messages = 20000000;
static LONG64 wrong;

static DWORD WINAPI producer(LPVOID arg) {
    (void)arg;
    for (LONG64 i = 0; i < messages; i++) {
        while (head - tail >= SLOTS) YieldProcessor();
        ring[head % SLOTS] = (unsigned long long)i * 2654435761u;  // the data, then the index: plain stores
        head = head + 1;
    }
    return 0;
}

static DWORD WINAPI consumer(LPVOID arg) {
    (void)arg;
    for (LONG64 i = 0; i < messages; i++) {
        while (head == i) YieldProcessor();
        if (ring[i % SLOTS] != (unsigned long long)i * 2654435761u) wrong++;
        tail = tail + 1;
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc > 1) messages = _atoi64(argv[1]);
    CRITICAL_SECTION cs;
    InitializeCriticalSection(&cs);
    HANDLE ev = CreateEventA(NULL, TRUE, FALSE, NULL);
    char *p = HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, 1 << 20);
    SYSTEMTIME st;
    GetSystemTime(&st);
    EnterCriticalSection(&cs);
    p[12345] = 1;
    LeaveCriticalSection(&cs);
    SetEvent(ev);
    if (WaitForSingleObject(ev, 1000) != WAIT_OBJECT_0 || p[12345] != 1 || st.wYear < 2000) {
        printf("spsc: the Win32 basics failed\n");
        return 2;
    }
    HANDLE t[2] = {CreateThread(NULL, 0, producer, NULL, 0, NULL), CreateThread(NULL, 0, consumer, NULL, 0, NULL)};
    WaitForMultipleObjects(2, t, TRUE, INFINITE);
    printf("spsc: %lld messages, %lld arrived wrong\n", (long long)messages, (long long)wrong);
    return wrong > 0;
}
