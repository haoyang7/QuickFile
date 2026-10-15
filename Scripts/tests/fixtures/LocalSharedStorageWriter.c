// Test-only child: retain an exclusive lock until the parent terminates us.
// The ready file is published only after the fragment has been written and aged.
#include <fcntl.h>
#include <stdio.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: QuickFileStorageWriterFixture fragment ready\n");
        return 2;
    }
    int fragment = open(argv[1], O_WRONLY | O_CREAT | O_EXCL | O_EXLOCK, 0600);
    if (fragment == -1) {
        perror("open fragment");
        return 1;
    }
    const char contents[] = "unpublished";
    if (write(fragment, contents, sizeof(contents) - 1) != sizeof(contents) - 1) {
        perror("write fragment");
        return 1;
    }
    time_t now = time(NULL);
    if (now == (time_t)-1) {
        perror("time");
        return 1;
    }
    const struct timespec old[2] = {{now - 172800, 0}, {now - 172800, 0}};
    if (futimens(fragment, old) == -1) {
        perror("age fragment");
        return 1;
    }
    int ready = open(argv[2], O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (ready == -1) {
        perror("open ready");
        return 1;
    }
    if (close(ready) == -1) {
        perror("close ready");
        return 1;
    }
    for (;;) pause();
}
