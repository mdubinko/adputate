#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <pthread.h>
#include <pwd.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/types.h>
#include <unistd.h>

#ifndef DNS_PORT
#define DNS_PORT 53
#endif
#define UDP_PACKET_MAX 4096
#define MAX_WORKERS 128
#define IO_TIMEOUT_SECONDS 4

static struct sockaddr_in backend_address;
static int udp_listener = -1;
static pthread_mutex_t worker_lock = PTHREAD_MUTEX_INITIALIZER;
static unsigned int active_workers = 0;

struct udp_job {
  unsigned char packet[UDP_PACKET_MAX];
  size_t packet_length;
  struct sockaddr_storage client_address;
  socklen_t client_address_length;
};

struct tcp_job {
  int client;
};

static void fatal(const char *message) {
  perror(message);
  exit(EXIT_FAILURE);
}

static int reserve_worker(void) {
  int reserved = 0;
  pthread_mutex_lock(&worker_lock);
  if (active_workers < MAX_WORKERS) {
    active_workers++;
    reserved = 1;
  }
  pthread_mutex_unlock(&worker_lock);
  return reserved;
}

static void release_worker(void) {
  pthread_mutex_lock(&worker_lock);
  active_workers--;
  pthread_mutex_unlock(&worker_lock);
}

static void set_timeouts(int socket_fd) {
  struct timeval timeout = {.tv_sec = IO_TIMEOUT_SECONDS, .tv_usec = 0};
  setsockopt(socket_fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
  setsockopt(socket_fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
}

static ssize_t read_exact(int socket_fd, void *buffer, size_t length) {
  size_t received = 0;
  while (received < length) {
    ssize_t count = recv(socket_fd, (unsigned char *)buffer + received,
                         length - received, 0);
    if (count <= 0) return count;
    received += (size_t)count;
  }
  return (ssize_t)received;
}

static int write_exact(int socket_fd, const void *buffer, size_t length) {
  size_t sent = 0;
  while (sent < length) {
    ssize_t count = send(socket_fd, (const unsigned char *)buffer + sent,
                         length - sent, 0);
    if (count <= 0) return -1;
    sent += (size_t)count;
  }
  return 0;
}

static int response_matches(const unsigned char *query, size_t query_length,
                            const unsigned char *response, size_t response_length) {
  return query_length >= 2 && response_length >= 4 &&
         query[0] == response[0] && query[1] == response[1] &&
         (response[2] & 0x80) != 0;
}

static void *forward_udp(void *context) {
  struct udp_job *job = context;
  unsigned char response[UDP_PACKET_MAX];
  int upstream = socket(AF_INET, SOCK_DGRAM, 0);
  if (upstream >= 0) {
    set_timeouts(upstream);
    if (connect(upstream, (struct sockaddr *)&backend_address,
                sizeof(backend_address)) != 0) {
      perror("UDP connect backend");
    } else if (send(upstream, job->packet, job->packet_length, 0) >= 0) {
      ssize_t length = recv(upstream, response, sizeof(response), 0);
      if (length > 0 && response_matches(job->packet, job->packet_length,
                                         response, (size_t)length)) {
        sendto(udp_listener, response, (size_t)length, 0,
               (struct sockaddr *)&job->client_address,
               job->client_address_length);
      } else if (length < 0) {
        perror("UDP recv backend");
      } else {
        fprintf(stderr, "UDP backend returned an invalid response\n");
      }
    } else {
      perror("UDP send backend");
    }
    close(upstream);
  } else {
    perror("UDP socket");
  }
  free(job);
  release_worker();
  return NULL;
}

static void *forward_tcp(void *context) {
  struct tcp_job *job = context;
  int client = job->client;
  int upstream = -1;
  unsigned char *query = NULL;
  unsigned char *response = NULL;
  free(job);
  set_timeouts(client);

  unsigned char size_buffer[2];
  if (read_exact(client, size_buffer, sizeof(size_buffer)) != 2) {
    perror("TCP read client length");
    goto done;
  }
  size_t query_length = ((size_t)size_buffer[0] << 8) | size_buffer[1];
  if (query_length < 12 || query_length > UINT16_MAX) goto done;
  query = malloc(query_length);
  if (query == NULL || read_exact(client, query, query_length) != (ssize_t)query_length) goto done;

  upstream = socket(AF_INET, SOCK_STREAM, 0);
  if (upstream < 0) { perror("TCP socket"); goto done; }
  set_timeouts(upstream);
  if (connect(upstream, (struct sockaddr *)&backend_address,
              sizeof(backend_address)) != 0) { perror("TCP connect backend"); goto done; }
  if (write_exact(upstream, size_buffer, sizeof(size_buffer)) != 0 ||
      write_exact(upstream, query, query_length) != 0) goto done;
  if (read_exact(upstream, size_buffer, sizeof(size_buffer)) != 2) {
    perror("TCP read backend length");
    goto done;
  }
  size_t response_length = ((size_t)size_buffer[0] << 8) | size_buffer[1];
  if (response_length < 12 || response_length > UINT16_MAX) goto done;
  response = malloc(response_length);
  if (response == NULL ||
      read_exact(upstream, response, response_length) != (ssize_t)response_length) goto done;
  if (!response_matches(query, query_length, response, response_length)) goto done;
  if (write_exact(client, size_buffer, sizeof(size_buffer)) != 0) goto done;
  write_exact(client, response, response_length);

done:
  free(query);
  free(response);
  if (upstream >= 0) close(upstream);
  close(client);
  release_worker();
  return NULL;
}

static int create_listener(const char *bind_address, int type) {
  int listener = socket(AF_INET, type, 0);
  if (listener < 0) fatal("socket");
  int enabled = 1;
  if (setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &enabled, sizeof(enabled)) != 0)
    fatal("setsockopt");

  struct sockaddr_in address = {0};
  address.sin_family = AF_INET;
  address.sin_port = htons(DNS_PORT);
  if (inet_pton(AF_INET, bind_address, &address.sin_addr) != 1) {
    fprintf(stderr, "Invalid bind address: %s\n", bind_address);
    exit(EXIT_FAILURE);
  }
  if (bind(listener, (struct sockaddr *)&address, sizeof(address)) != 0)
    fatal("bind");
  if (type == SOCK_STREAM && listen(listener, 128) != 0) fatal("listen");
  return listener;
}

static int start_thread(void *(*function)(void *), void *context) {
  pthread_t thread;
  pthread_attr_t attributes;
  int result;
  pthread_attr_init(&attributes);
  pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED);
  pthread_attr_setstacksize(&attributes, 128 * 1024);
  result = pthread_create(&thread, &attributes, function, context);
  pthread_attr_destroy(&attributes);
  return result;
}

static void drop_privileges(void) {
  if (geteuid() != 0) return;
  struct passwd *account = getpwnam("nobody");
  if (account == NULL) fatal("getpwnam");
  if (setgroups(0, NULL) != 0 || setgid(account->pw_gid) != 0 ||
      setuid(account->pw_uid) != 0) fatal("drop privileges");
}

int main(int argc, char **argv) {
  if (argc != 4) {
    fprintf(stderr, "Usage: %s <bind-address> <backend-address> <backend-port>\n", argv[0]);
    return EXIT_FAILURE;
  }
  char *port_end = NULL;
  long backend_port = strtol(argv[3], &port_end, 10);
  if (*argv[3] == '\0' || *port_end != '\0' || backend_port < 1024 || backend_port > 65535 ||
      inet_pton(AF_INET, argv[2], &backend_address.sin_addr) != 1) {
    fprintf(stderr, "Invalid backend address or port.\n");
    return EXIT_FAILURE;
  }
  backend_address.sin_family = AF_INET;
  backend_address.sin_port = htons((uint16_t)backend_port);

  udp_listener = create_listener(argv[1], SOCK_DGRAM);
  int tcp_listener = create_listener(argv[1], SOCK_STREAM);
  drop_privileges();
  signal(SIGPIPE, SIG_IGN);

  for (;;) {
    fd_set readers;
    FD_ZERO(&readers);
    FD_SET(udp_listener, &readers);
    FD_SET(tcp_listener, &readers);
    int maximum = udp_listener > tcp_listener ? udp_listener : tcp_listener;
    if (select(maximum + 1, &readers, NULL, NULL, NULL) < 0) {
      if (errno == EINTR) continue;
      fatal("select");
    }
    if (FD_ISSET(udp_listener, &readers)) {
      struct udp_job *job = calloc(1, sizeof(*job));
      if (job != NULL) {
        job->client_address_length = sizeof(job->client_address);
        ssize_t length = recvfrom(udp_listener, job->packet, sizeof(job->packet), 0,
                                  (struct sockaddr *)&job->client_address,
                                  &job->client_address_length);
        if (length >= 12 && reserve_worker()) {
          job->packet_length = (size_t)length;
          if (start_thread(forward_udp, job) != 0) {
            release_worker();
            free(job);
          }
        } else {
          free(job);
        }
      }
    }
    if (FD_ISSET(tcp_listener, &readers)) {
      int client = accept(tcp_listener, NULL, NULL);
      if (client >= 0) {
        struct tcp_job *job = malloc(sizeof(*job));
        if (job != NULL && reserve_worker()) {
          job->client = client;
          if (start_thread(forward_tcp, job) != 0) {
            release_worker();
            free(job);
            close(client);
          }
        } else {
          free(job);
          close(client);
        }
      }
    }
  }
}
