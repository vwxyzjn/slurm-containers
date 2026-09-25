/* SPDX-License-Identifier: GPL-2.0-or-later */
#define _GNU_SOURCE
#include "task_delegation.h"
#include <signal.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/wait.h>

#define CHECK(x)                                                               \
	do {                                                                   \
		if (!(x)) {                                                    \
			fprintf(stderr, "%s:%d: %s: %s\n", __FILE__, __LINE__, \
				#x, strerror(errno));                          \
			exit(1);                                               \
		}                                                              \
	} while (0)
#define UID 65534

static int child(int dir, const char *name)
{
	CHECK(!mkdirat(dir, name, 0755));
	int fd = _deleg_open_dir(dir, name);
	CHECK(fd >= 0);
	return fd;
}

static void enter(int fd, pid_t pid)
{
	char buf[32];
	snprintf(buf, sizeof(buf), "%d", pid);
	CHECK(!_deleg_write(fd, "cgroup.procs", buf));
}

static void unprivileged(void)
{
	CHECK(!setgid(UID));
	CHECK(!setuid(UID));
}

static void reaped(pid_t pid, int sig)
{
	int status;
	CHECK(waitpid(pid, &status, 0) == pid);
	if (sig)
		CHECK(WIFSIGNALED(status) && WTERMSIG(status) == sig);
	else
		CHECK(WIFEXITED(status) && !WEXITSTATUS(status));
}

static pid_t sleeper(int leaf)
{
	int ready[2];
	char byte;
	CHECK(!pipe(ready));
	pid_t pid = fork();
	CHECK(pid >= 0);
	if (!pid) {
		close(ready[0]);
		enter(leaf, getpid());
		unprivileged();
		CHECK(write(ready[1], "x", 1) == 1);
		close(ready[1]);
		for (;;)
			pause();
	}
	close(ready[1]);
	CHECK(read(ready[0], &byte, 1) == 1);
	close(ready[0]);
	return pid;
}

static int count_pid(pid_t pid, void *arg)
{
	pid_t *expected = arg;
	if (pid == expected[0])
		expected[1]++;
	return 0;
}

static int terminate_pid(pid_t pid, void *arg)
{
	(void)arg;
	return kill(pid, SIGTERM);
}

static long event(int dir, const char *wanted)
{
	int fd = openat(dir, "memory.events", O_RDONLY);
	CHECK(fd >= 0);
	FILE *f = fdopen(fd, "r");
	CHECK(f);
	char key[64];
	long n, result = -1;
	while (fscanf(f, "%63s %ld", key, &n) == 2)
		if (!strcmp(key, wanted))
			result = n;
	CHECK(!fclose(f));
	CHECK(result >= 0);
	return result;
}

int main(int argc, char **argv)
{
	CHECK(argc == 2);
	alarm(60); /* A hang is a failure; no timing-dependent success
		      assertions. */
	int root = open(argv[1], O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
	CHECK(root >= 0);
	CHECK(!_deleg_check_fs(root));
	CHECK(!_deleg_write(root, "cgroup.subtree_control", "+memory"));
	int task = child(root, "task");
	int other = child(root, "other");
	CHECK(!_deleg_write(task, "memory.max", "100663296"));
	CHECK(!_deleg_write(task, "memory.swap.max", "0"));
	CHECK(!_deleg_prepare(task, UID, UID));
	CHECK(!_deleg_prepare(other, UID, UID));
	int main = _deleg_open_dir(task, DELEGATION_LEAF);
	int peer = _deleg_open_dir(other, DELEGATION_LEAF);
	CHECK(main >= 0 && peer >= 0);
	pid_t sibling = sleeper(peer);
	pid_t supervisor = sleeper(main);
	pid_t tester = fork();
	CHECK(tester >= 0);
	if (!tester) {
		enter(main, getpid());
		unprivileged();
		int delegated = _deleg_open_dir(task, DELEGATION_DIR);
		CHECK(delegated >= 0);
		CHECK(_deleg_write(task, "memory.max", "max") < 0 &&
		      errno == EACCES);
		CHECK(_deleg_write(delegated, "memory.max", "max") < 0 &&
		      errno == EACCES);
		CHECK(_deleg_write(task, "cgroup.max.descendants", "max") < 0 &&
		      errno == EACCES);
		CHECK(_deleg_write(task, "cgroup.procs", "0") < 0 &&
		      errno == EACCES);
		char pid[32];
		snprintf(pid, sizeof(pid), "%d", sibling);
		CHECK(_deleg_write(main, "cgroup.procs", pid) < 0 &&
		      errno == EACCES);
		CHECK(_deleg_write(main, "cgroup.subtree_control", "+cpu") < 0);
		int worker = child(delegated, "worker");
		CHECK(!_deleg_write(worker, "memory.max", "33554432"));
		CHECK(!_deleg_write(worker, "memory.swap.max", "0"));
		CHECK(!_deleg_write(worker, "memory.oom.group", "1"));
		pid_t allocator = fork();
		CHECK(allocator >= 0);
		if (!allocator) {
			enter(worker, getpid());
			size_t size = 256 * 1024 * 1024;
			volatile char *memory =
			    mmap(NULL, size, PROT_READ | PROT_WRITE,
				 MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
			CHECK(memory != MAP_FAILED);
			for (size_t i = 0; i < size; i += 4096)
				memory[i] = 1;
			_exit(2); /* The kernel must kill us before this
				     allocation completes. */
		}
		reaped(allocator, SIGKILL);
		CHECK(event(worker, "oom_kill") >= 1);
		CHECK(!kill(supervisor, 0) && !kill(sibling, 0));
		/* Exercise nested placement and both kernel hierarchy bounds.
		 */
		int branch = child(delegated, "branch");
		CHECK(
		    !_deleg_write(branch, "cgroup.subtree_control", "+memory"));
		int leaf = child(branch, "leaf");
		enter(leaf, getpid());
		int depth = child(worker, "a");
		for (int i = 0; i < 3; i++) {
			int next = child(depth, "a");
			close(depth);
			depth = next;
		}
		CHECK(mkdirat(depth, "too-deep", 0755) < 0 && errno == EAGAIN);
		close(depth);
		int created = 0;
		for (int i = 0; i < 300; i++) {
			char name[32];
			snprintf(name, sizeof(name), "unused-%d", i);
			if (mkdirat(delegated, name, 0755)) {
				CHECK(errno == EAGAIN);
				break;
			}
			created++;
		}
		CHECK(created > 200 && created < 258);
		close(leaf);
		close(branch);
		close(worker);
		close(delegated);
		_exit(0);
	}
	reaped(tester, 0);
	CHECK(event(task, "oom_kill") >=
	      1); /* Hierarchical accounting survives. */
	int nested = _deleg_open_dir(task, "delegated/branch/leaf");
	CHECK(nested >= 0);
	pid_t descendant = sleeper(nested);
	pid_t expected[] = {descendant, 0};
	CHECK(!_deleg_walk(task, count_pid, expected, false));
	CHECK(expected[1] == 1);
	CHECK(_deleg_cleanup(task) < 0 && errno == EBUSY);
	CHECK(!_deleg_walk(task, terminate_pid, NULL, false));
	reaped(supervisor, SIGTERM);
	reaped(descendant, SIGTERM);
	close(nested);
	CHECK(!kill(sibling, 0));
	CHECK(!_deleg_cleanup(task));
	CHECK(!_deleg_walk(other, terminate_pid, NULL, false));
	reaped(sibling, SIGTERM);
	CHECK(!_deleg_cleanup(other));
	close(main);
	close(peer);
	close(task);
	close(other);
	CHECK(!unlinkat(root, "task", AT_REMOVEDIR));
	CHECK(!unlinkat(root, "other", AT_REMOVEDIR));
	close(root);
	puts("PASS: delegation, permissions, same-UID containment, OOM "
	     "isolation, bounds, PID tracking, SIGTERM and cleanup");
	return 0;
}
