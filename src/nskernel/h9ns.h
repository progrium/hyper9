/*
 * The namespace kernel's native API (design/namespace-kernel.md, The
 * native API): libh9ns.a, h9's kernel with nothing for running programs,
 * holding namespaces composed through /ns and served over 9P2000.
 *
 * Link libh9ns.a with the C library and threads (-lc -lpthread).
 */
#ifndef H9NS_H
#define H9NS_H

#ifdef __cplusplus
extern "C" {
#endif

/* Boots the kernel and namespace 0, once. Returns 0, or -1 (h9ns_error). */
int h9ns_boot(void);

/*
 * Serves 9P2000 (or 9P2000.L) on fd, attached to namespace aname, its id
 * as a decimal string ("" or NULL for 0), until the far end hangs up. A
 * Tattach naming another namespace fails. The kernel takes fd. Returns 0
 * once serving has started, or -1.
 */
int h9ns_serve(int fd, const char *aname);

/*
 * Names fd, a connection to a 9P server, so a ctl line can mount it as
 * fd!name. Each mount uses a duplicate; the kernel keeps fd, and closes
 * it if name is given again. Returns 0, or -1.
 */
int h9ns_addfd(const char *name, int fd);

/* Why the last h9ns_boot failed. */
const char *h9ns_error(void);

#ifdef __cplusplus
}
#endif

#endif
