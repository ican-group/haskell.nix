#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/eventfd.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include <poll.h>
#include <signal.h>

#define DEFAULT_ITERATIONS UINT64_C(1000)
#define MAX_ITERATIONS UINT64_C(10000000)
#define MAX_TIMEOUT_MS UINT64_C(3600000)
#define DEFAULT_PROGRESS_EVERY UINT64_C(100)

typedef struct {
    struct pollfd *fds;
    int pipe_write;
    int event_write;
    pthread_mutex_t mutex;
    pthread_cond_t condition;
    uint64_t acknowledgements;
    uint64_t readiness_cycles;
    atomic_bool stopping;
    atomic_bool poller_done;
    atomic_bool poller_failed;
    atomic_int poller_error_code;
    bool finite_timeout;
    bool use_ppoll;
    uint64_t timeout_ms;
    struct timespec timeout;
    bool timing;
    uint64_t poll_ns;
} poll_state;

static uint64_t elapsed_ns(const struct timespec *start, const struct timespec *end) {
    int64_t sec = (int64_t)end->tv_sec - (int64_t)start->tv_sec;
    int64_t nsec = (int64_t)end->tv_nsec - (int64_t)start->tv_nsec;
    if (nsec < 0) {
        sec -= 1;
        nsec += INT64_C(1000000000);
    }
    return (uint64_t)sec * UINT64_C(1000000000) + (uint64_t)nsec;
}

static int set_nonblocking(int fd) {
    int flags = fcntl(fd, F_GETFL);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) return -1;
    return 0;
}

static int write_pipe_byte(int fd) {
    const unsigned char byte = 1;
    ssize_t n;
    do { n = write(fd, &byte, sizeof byte); } while (n < 0 && errno == EINTR);
    return n == (ssize_t)sizeof byte ? 0 : -1;
}

static int wake_poller(poll_state *state) {
    uint64_t one = 1;
    ssize_t n;
    if (write_pipe_byte(state->pipe_write) != 0) return -1;
    do { n = write(state->event_write, &one, sizeof one); } while (n < 0 && errno == EINTR);
    return n == (ssize_t)sizeof one ? 0 : -1;
}

static int drain_pipe(int fd) {
    unsigned char bytes[128];
    for (;;) {
        ssize_t n = read(fd, bytes, sizeof bytes);
        if (n > 0) continue;
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return 0;
        return n == 0 ? 0 : -1;
    }
}

static int drain_eventfd(int fd) {
    uint64_t value;
    ssize_t n;
    do { n = read(fd, &value, sizeof value); } while (n < 0 && errno == EINTR);
    if (n == (ssize_t)sizeof value) return 0;
    return n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) ? 0 : -1;
}

static char poller_error;

static void notify_poller_state(poll_state *state) {
    if (pthread_mutex_lock(&state->mutex) == 0) {
        (void)pthread_cond_broadcast(&state->condition);
        (void)pthread_mutex_unlock(&state->mutex);
    }
}

static void *poller_finish(poll_state *state, int error_code) {
    if (error_code != 0) {
        atomic_store_explicit(&state->poller_error_code, error_code, memory_order_relaxed);
        atomic_store_explicit(&state->poller_failed, true, memory_order_release);
    }
    atomic_store_explicit(&state->poller_done, true, memory_order_release);
    notify_poller_state(state);
    return error_code == 0 ? NULL : &poller_error;
}

static void *poller_main(void *argument) {
    poll_state *state = argument;
    unsigned int seen = 0U;
    for (;;) {
        struct timespec start, end;
        int result;
        int poll_error;
        if (state->timing && clock_gettime(CLOCK_MONOTONIC, &start) != 0) return poller_finish(state, errno);
        if (state->use_ppoll) {
            result = ppoll(state->fds, 2, state->finite_timeout ? &state->timeout : NULL, NULL);
        } else {
            int timeout = state->finite_timeout ? (int)state->timeout_ms : -1;
            result = poll(state->fds, 2, timeout);
        }
        poll_error = errno;
        if (state->timing && clock_gettime(CLOCK_MONOTONIC, &end) != 0) return poller_finish(state, errno);
        if (result < 0 && poll_error == EINTR) continue;
        if (result < 0) return poller_finish(state, poll_error);
        if (state->timing) state->poll_ns += elapsed_ns(&start, &end);
        if ((state->fds[0].revents & POLLIN) != 0) {
            if (drain_pipe(state->fds[0].fd) != 0) return poller_finish(state, errno);
            seen |= 1U;
        }
        if ((state->fds[1].revents & POLLIN) != 0) {
            if (drain_eventfd(state->fds[1].fd) != 0) return poller_finish(state, errno);
            seen |= 2U;
        }
        if ((state->fds[0].revents & (POLLERR | POLLHUP | POLLNVAL)) != 0 ||
            (state->fds[1].revents & (POLLERR | POLLHUP | POLLNVAL)) != 0) return poller_finish(state, EIO);

        if (atomic_load_explicit(&state->stopping, memory_order_acquire)) return poller_finish(state, 0);
        if (seen == 3U) {
            int rc = pthread_mutex_lock(&state->mutex);
            if (rc != 0) return poller_finish(state, rc);
            state->readiness_cycles += 1U;
            state->acknowledgements += 1U;
            seen = 0U;
            rc = pthread_cond_broadcast(&state->condition);
            {
                int unlock_rc = pthread_mutex_unlock(&state->mutex);
                if (unlock_rc != 0 || rc != 0) return poller_finish(state, unlock_rc != 0 ? unlock_rc : rc);
            }
        }
    }
}

static int wait_for_ack(poll_state *state, uint64_t target) {
    int rc = pthread_mutex_lock(&state->mutex);
    if (rc != 0) return rc;
    while (state->acknowledgements < target) {
        struct timespec deadline;
        if (atomic_load_explicit(&state->poller_failed, memory_order_acquire) ||
            atomic_load_explicit(&state->poller_done, memory_order_acquire)) {
            rc = atomic_load_explicit(&state->poller_error_code, memory_order_relaxed);
            if (rc == 0) rc = EIO;
            break;
        }
        if (clock_gettime(CLOCK_REALTIME, &deadline) != 0) {
            rc = errno;
            break;
        }
        deadline.tv_sec += 1;
        rc = pthread_cond_timedwait(&state->condition, &state->mutex, &deadline);
        if (rc == ETIMEDOUT) rc = 0;
        else if (rc != 0) break;
    }
    if (rc == 0 && (atomic_load_explicit(&state->poller_failed, memory_order_acquire) ||
                    atomic_load_explicit(&state->poller_done, memory_order_acquire))) {
        rc = atomic_load_explicit(&state->poller_error_code, memory_order_relaxed);
        if (rc == 0) rc = EIO;
    }
    if (pthread_mutex_unlock(&state->mutex) != 0 && rc == 0) rc = EINVAL;
    return rc;
}

static int write_all(int fd, const char *buffer, size_t length) {
    size_t offset = 0U;
    while (offset < length) {
        ssize_t written = write(fd, buffer + offset, length - offset);
        if (written > 0) offset += (size_t)written;
        else if (written < 0 && errno == EINTR) continue;
        else return -1;
    }
    return 0;
}

static int report_progress(uint64_t iteration, uint64_t forks_completed,
                          uint64_t progress_every, const char *phase) {
    char line[160];
    int length;
    if (iteration != 1U && iteration % progress_every != 0U) return 0;
    length = snprintf(line, sizeof line,
        "progress phase=%s iteration=%" PRIu64 " forks=%" PRIu64 "\n",
        phase, iteration, forks_completed);
    if (length < 0 || (size_t)length >= sizeof line) {
        errno = EOVERFLOW;
        return -1;
    }
    return write_all(STDERR_FILENO, line, (size_t)length);
}

static bool parse_u64(const char *text, uint64_t maximum, uint64_t *value) {
    char *end = NULL;
    unsigned long long parsed;
    if (text == NULL || *text == '\0' || *text == '-') return false;
    errno = 0;
    parsed = strtoull(text, &end, 10);
    if (errno != 0 || end == text || *end != '\0' || parsed > maximum) return false;
    *value = (uint64_t)parsed;
    return true;
}

static void usage(const char *program) {
    (void)fprintf(stderr,
        "Usage: %s [--api poll|ppoll] [--iterations N] [--timeout-ms N] [--progress-every N] [--timing]\n"
        "  --api API          libc wait call: poll or ppoll (default ppoll)\n"
        "  --iterations N     fork cycles (1..%" PRIu64 ", default %" PRIu64 ")\n"
        "  --timeout-ms N     finite wait timeout (0..%" PRIu64 "); omit for indefinite\n"
        "  --progress-every N report phases every N cycles (default %" PRIu64 ")\n"
        "  --timing           include monotonic wait-call and total elapsed time\n",
        program, MAX_ITERATIONS, DEFAULT_ITERATIONS, MAX_TIMEOUT_MS, DEFAULT_PROGRESS_EVERY);
}

int main(int argc, char **argv) {
    uint64_t iterations = DEFAULT_ITERATIONS;
    uint64_t timeout_ms = 0U;
    uint64_t progress_every = DEFAULT_PROGRESS_EVERY;
    bool finite_timeout = false, timing = false;
    bool use_ppoll = true;
    int pipe_fds[2] = {-1, -1};
    int event_fd = -1, status = EXIT_FAILURE;
    poll_state state;
    pthread_t poller;
    bool poller_started = false, mutex_ready = false, condition_ready = false;
    uint64_t forks_completed = 0U;
    int run_error = 0;
    struct timespec total_start, total_end;
    void *thread_result = NULL;

    (void)memset(&state, 0, sizeof state);
    state.fds = NULL;
    state.pipe_write = -1;
    state.event_write = -1;
    for (int i = 1; i < argc; ++i) {
        if (strcmp(argv[i], "--api") == 0 && i + 1 < argc) {
            const char *api = argv[++i];
            if (strcmp(api, "poll") == 0) use_ppoll = false;
            else if (strcmp(api, "ppoll") == 0) use_ppoll = true;
            else goto bad_args;
        } else if (strcmp(argv[i], "--iterations") == 0 && i + 1 < argc) {
            if (!parse_u64(argv[++i], MAX_ITERATIONS, &iterations) || iterations == 0U) goto bad_args;
        } else if (strcmp(argv[i], "--timeout-ms") == 0 && i + 1 < argc) {
            if (!parse_u64(argv[++i], MAX_TIMEOUT_MS, &timeout_ms)) goto bad_args;
            finite_timeout = true;
        } else if (strcmp(argv[i], "--progress-every") == 0 && i + 1 < argc) {
            if (!parse_u64(argv[++i], MAX_ITERATIONS, &progress_every) || progress_every == 0U) goto bad_args;
        } else if (strcmp(argv[i], "--timing") == 0) {
            timing = true;
        } else {
            goto bad_args;
        }
    }
    state.timing = timing;
    state.finite_timeout = finite_timeout;
    state.use_ppoll = use_ppoll;
    state.timeout_ms = timeout_ms;
    state.timeout.tv_sec = (time_t)(timeout_ms / UINT64_C(1000));
    state.timeout.tv_nsec = (long)((timeout_ms % UINT64_C(1000)) * UINT64_C(1000000));
    atomic_init(&state.stopping, false);
    atomic_init(&state.poller_done, false);
    atomic_init(&state.poller_failed, false);
    atomic_init(&state.poller_error_code, 0);
    state.fds = calloc(2U, sizeof *state.fds);
    if (state.fds == NULL) goto cleanup;
    if (pipe(pipe_fds) != 0 || set_nonblocking(pipe_fds[0]) != 0 || set_nonblocking(pipe_fds[1]) != 0) goto cleanup;
    event_fd = eventfd(0U, EFD_NONBLOCK | EFD_CLOEXEC);
    if (event_fd < 0) goto cleanup;
    state.fds[0].fd = pipe_fds[0];
    state.fds[0].events = POLLIN;
    state.fds[1].fd = event_fd;
    state.fds[1].events = POLLIN;
    state.pipe_write = pipe_fds[1];
    state.event_write = event_fd;
    if (pthread_mutex_init(&state.mutex, NULL) != 0) goto cleanup;
    mutex_ready = true;
    if (pthread_cond_init(&state.condition, NULL) != 0) goto cleanup;
    condition_ready = true;
    if (timing && clock_gettime(CLOCK_MONOTONIC, &total_start) != 0) goto cleanup;
    if (pthread_create(&poller, NULL, poller_main, &state) != 0) goto cleanup;
    poller_started = true;

    for (uint64_t i = 1U; i <= iterations; ++i) {
        pid_t child;
        int child_status;
        pid_t waited;
        if (wake_poller(&state) != 0) {
            run_error = errno;
            goto cleanup;
        }
        if (report_progress(i, forks_completed, progress_every, "before_ack") != 0) {
            run_error = errno;
            goto cleanup;
        }
        run_error = wait_for_ack(&state, i);
        if (run_error != 0) goto cleanup;
        if (report_progress(i, forks_completed, progress_every, "before_fork") != 0) {
            run_error = errno;
            goto cleanup;
        }
        child = fork();
        if (child < 0) {
            run_error = errno;
            goto cleanup;
        }
        if (child == 0) _exit(0);
        do { waited = waitpid(child, &child_status, 0); } while (waited < 0 && errno == EINTR);
        if (waited != child) {
            run_error = errno != 0 ? errno : ECHILD;
            goto cleanup;
        }
        if (!WIFEXITED(child_status) || WEXITSTATUS(child_status) != 0) {
            run_error = EIO;
            goto cleanup;
        }
        forks_completed += 1U;
        if (report_progress(i, forks_completed, progress_every, "after_waitpid") != 0) {
            run_error = errno;
            goto cleanup;
        }
    }
    atomic_store_explicit(&state.stopping, true, memory_order_release);
    if (wake_poller(&state) != 0) {
        run_error = errno;
        goto cleanup;
    }
    if (pthread_join(poller, &thread_result) != 0) goto cleanup;
    poller_started = false;
    if (thread_result != NULL) {
        run_error = atomic_load_explicit(&state.poller_error_code, memory_order_relaxed);
        if (run_error == 0) run_error = EIO;
        goto cleanup;
    }
    if (timing && clock_gettime(CLOCK_MONOTONIC, &total_end) != 0) goto cleanup;
    status = EXIT_SUCCESS;
    (void)printf("forks=%" PRIu64 " readiness_cycles=%" PRIu64 " api=%s mode=%s",
        forks_completed, state.readiness_cycles, use_ppoll ? "ppoll" : "poll",
        finite_timeout ? "finite" : "indefinite");
    if (finite_timeout) (void)printf(" timeout_ms=%" PRIu64, timeout_ms);
    if (timing) (void)printf(" wait_ms=%.3f total_ms=%.3f",
        (double)state.poll_ns / 1000000.0,
        (double)elapsed_ns(&total_start, &total_end) / 1000000.0);
    (void)putchar('\n');
    goto cleanup;

bad_args:
    usage(argv[0]);
cleanup:
    if (run_error != 0) {
        (void)fprintf(stderr, "harness error: %s (%d)\n", strerror(run_error), run_error);
    }
    if (poller_started) {
        if (!atomic_load_explicit(&state.poller_done, memory_order_acquire)) {
            atomic_store_explicit(&state.stopping, true, memory_order_release);
            if (wake_poller(&state) != 0) {
                (void)fprintf(stderr, "fatal: cannot wake poller during cleanup; exiting without join\n");
                _Exit(EXIT_FAILURE);
            }
        }
        if (pthread_join(poller, NULL) != 0) {
            (void)fprintf(stderr, "fatal: cannot join poller during cleanup\n");
            _Exit(EXIT_FAILURE);
        }
        poller_started = false;
    }
    if (condition_ready) (void)pthread_cond_destroy(&state.condition);
    if (mutex_ready) (void)pthread_mutex_destroy(&state.mutex);
    if (event_fd >= 0) (void)close(event_fd);
    if (pipe_fds[0] >= 0) (void)close(pipe_fds[0]);
    if (pipe_fds[1] >= 0) (void)close(pipe_fds[1]);
    free(state.fds);
    return status;
}
