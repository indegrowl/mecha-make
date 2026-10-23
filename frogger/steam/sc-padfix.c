// LD_PRELOAD shim for Steam's ARM64 streaming_client on Iris.
// The client asks for a 128-aligned NV12 capture width (e.g. 1792 for a 1730-wide
// stream) and samples the decoded texture with linear filtering up to the visible
// edge, so whatever lies past it bleeds in as a one-pixel seam. That padding is
// either never written (zero = green in YUV) or, when the stream width is not a
// multiple of the encoder's block size, the encoder's own padding, which the
// decoder writes on every frame and which is green too. So after every decoded
// frame, before the client sees it, repeat the last visible column and row into
// the padding.
#define _GNU_SOURCE
#include <fcntl.h>
#include <linux/dma-buf.h>
#include <linux/ioctl.h>
#include <linux/videodev2.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

#define MAXBUF 64

// Mesa exports the capture images read-only; ask DRM for RDWR so we can mmap them writable.
struct drm_prime_handle_ { uint32_t handle, flags; int32_t fd; };
#define DRM_IOCTL_PRIME_HANDLE_TO_FD_ _IOWR('d', 0x2d, struct drm_prime_handle_)

static int cap_w, cap_h, cap_stride, vis_w, vis_h;
// The client closes its dmabuf fd right after QBUF, so each capture buffer is
// mapped at QBUF and kept (with a dup of its fd for cache syncs) by V4L2 index.
static struct buf { ino_t ino; int fd; uint8_t *map; size_t size; } bufs[MAXBUF];
static int dbg = -1;

#ifdef SC_PADFIX_TEST
#define real_ioctl test_real_ioctl
#else
static long real_ioctl(int fd, unsigned long req, void *arg)
{
	return syscall(SYS_ioctl, fd, req, arg);
}
#endif

static void logf_(const char *fmt, ...)
{
	if (dbg < 0)
		dbg = getenv("SC_PADFIX_DEBUG") != NULL;
	if (!dbg)
		return;
	va_list ap;
	va_start(ap, fmt);
	fprintf(stderr, "[padfix] ");
	vfprintf(stderr, fmt, ap);
	va_end(ap);
}

// Repeat the last visible column and row of an NV12 frame into its padding.
static void fill_padding(uint8_t *p, int stride, int h, int vw, int vh)
{
	uint8_t *uv = p + (size_t)stride * h;
	int cw = (vw + 1) & ~1, ch = (vh + 1) / 2;
	for (int y = 0; y < vh; y++) {
		uint8_t *row = p + (size_t)y * stride;
		memset(row + vw, row[vw - 1], stride - vw);
	}
	for (int y = vh; y < h; y++)
		memcpy(p + (size_t)y * stride, p + (size_t)(vh - 1) * stride, stride);
	for (int y = 0; y < ch; y++) {
		uint8_t *row = uv + (size_t)y * stride;
		for (int x = cw; x + 1 < stride; x += 2) {
			row[x] = row[cw - 2];
			row[x + 1] = row[cw - 1];
		}
	}
	for (int y = ch; y < h / 2; y++)
		memcpy(uv + (size_t)y * stride, uv + (size_t)(ch - 1) * stride, stride);
}

static void forget_buffers(void)
{
	for (int i = 0; i < MAXBUF; i++) {
		if (bufs[i].map)
			munmap(bufs[i].map, bufs[i].size);
		if (bufs[i].map)
			close(bufs[i].fd);
		bufs[i] = (struct buf){ 0 };
	}
}

static void query_visible(int fd)
{
	struct v4l2_selection sel = {
		.type = V4L2_BUF_TYPE_VIDEO_CAPTURE,
		.target = V4L2_SEL_TGT_COMPOSE,
	};
	if (real_ioctl(fd, VIDIOC_G_SELECTION, &sel) == 0 && sel.r.width) {
		vis_w = sel.r.left + sel.r.width;
		vis_h = sel.r.top + sel.r.height;
	}
	logf_("capture %dx%d stride %d visible %dx%d\n", cap_w, cap_h, cap_stride, vis_w, vis_h);
}

static int is_capture_dmabuf(const struct v4l2_buffer *b)
{
	return b->type == V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE && b->memory == V4L2_MEMORY_DMABUF &&
	       b->m.planes && b->length >= 1 && b->index < MAXBUF && cap_stride > 0;
}

static void remember(const struct v4l2_buffer *b)
{
	if (!is_capture_dmabuf(b))
		return;
	struct buf *s = &bufs[b->index];
	int dmafd = b->m.planes[0].m.fd;
	struct stat st;
	if (fstat(dmafd, &st) || (s->map && s->ino == st.st_ino))
		return;
	if (s->map) {
		munmap(s->map, s->size);
		close(s->fd);
		s->map = NULL;
	}
	size_t size = (size_t)cap_stride * cap_h * 3 / 2;
	uint8_t *p = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, dmafd, 0);
	if (p == MAP_FAILED) {
		logf_("mmap fd %d failed: %m\n", dmafd);
		return;
	}
	*s = (struct buf){ st.st_ino, dup(dmafd), p, size };
	logf_("mapped buffer %u\n", b->index);
}

static void fix_frame(const struct v4l2_buffer *b)
{
	if (!is_capture_dmabuf(b) || vis_w <= 0 || vis_h <= 0 || vis_w > cap_stride || vis_h > cap_h ||
	    (vis_w == cap_stride && vis_h == cap_h))
		return;
	struct buf *s = &bufs[b->index];
	if (!s->map)
		return;
	struct dma_buf_sync sync = { DMA_BUF_SYNC_START | DMA_BUF_SYNC_RW };
	real_ioctl(s->fd, DMA_BUF_IOCTL_SYNC, &sync);
	fill_padding(s->map, cap_stride, cap_h, vis_w, vis_h);
	sync.flags = DMA_BUF_SYNC_END | DMA_BUF_SYNC_RW;
	real_ioctl(s->fd, DMA_BUF_IOCTL_SYNC, &sync);
}

int ioctl(int fd, unsigned long req, ...)
{
	va_list ap;
	va_start(ap, req);
	void *arg = va_arg(ap, void *);
	va_end(ap);

	if (req == VIDIOC_QBUF)
		remember(arg); // the fd is only valid now
	else if (req == DRM_IOCTL_PRIME_HANDLE_TO_FD_)
		((struct drm_prime_handle_ *)arg)->flags |= O_RDWR;

	long r = real_ioctl(fd, req, arg);
	if (r < 0)
		return r;

	if (req == VIDIOC_DQBUF) {
		fix_frame(arg); // decoded, not yet seen by the client
	} else if (req == VIDIOC_S_FMT || req == VIDIOC_G_FMT) {
		struct v4l2_format *f = arg;
		if (f->type == V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE &&
		    f->fmt.pix_mp.pixelformat == V4L2_PIX_FMT_NV12 && f->fmt.pix_mp.num_planes == 1) {
			int w = f->fmt.pix_mp.width, h = f->fmt.pix_mp.height;
			int stride = f->fmt.pix_mp.plane_fmt[0].bytesperline;
			int changed = w != cap_w || h != cap_h || stride != cap_stride;
			cap_w = w;
			cap_h = h;
			cap_stride = stride;
			vis_w = w;
			vis_h = h;
			if (changed || req == VIDIOC_S_FMT)
				forget_buffers();
			query_visible(fd);
		}
	} else if (req == VIDIOC_STREAMON) {
		if (cap_w && *(int *)arg == V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE)
			query_visible(fd);
	}
	return r;
}
