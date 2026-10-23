// Spike: LD_PRELOAD shim for Steam's ARM64 streaming_client on Iris.
// The client asks for a 128-aligned NV12 capture width (e.g. 1792 for a 1728-wide
// stream) and samples the decoded texture with linear filtering up to the visible
// edge, so the never-written padding columns (zero = green in YUV) bleed in as a
// one-pixel green seam. Paint the padding black once per capture buffer.
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
// The client closes its dmabuf fd right after QBUF, so paint at QBUF time and
// remember painted buffers by dmabuf inode (fd numbers change every queue).
static ino_t done_ino[MAXBUF];
static int ndone;
static int dbg = -1;

static long real_ioctl(int fd, unsigned long req, void *arg)
{
	return syscall(SYS_ioctl, fd, req, arg);
}

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

static void paint(int dmafd)
{
	size_t size = (size_t)cap_stride * cap_h * 3 / 2;
	uint8_t *p = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, dmafd, 0);
	if (p == MAP_FAILED) {
		logf_("mmap fd %d failed: %m\n", dmafd);
		return;
	}
	struct dma_buf_sync sync = { DMA_BUF_SYNC_START | DMA_BUF_SYNC_RW };
	real_ioctl(dmafd, DMA_BUF_IOCTL_SYNC, &sync);
	int pad = cap_stride - vis_w;
	uint8_t *uv = p + (size_t)cap_stride * cap_h;
	for (int y = 0; y < cap_h; y++)
		memset(p + (size_t)y * cap_stride + vis_w, 16, pad); // black luma (limited range)
	for (int y = 0; y < cap_h / 2; y++)
		memset(uv + (size_t)y * cap_stride + (vis_w & ~1), 128, pad + (vis_w & 1)); // neutral chroma
	sync.flags = DMA_BUF_SYNC_END | DMA_BUF_SYNC_RW;
	real_ioctl(dmafd, DMA_BUF_IOCTL_SYNC, &sync);
	munmap(p, size);
	logf_("painted fd %d cols %d..%d\n", dmafd, vis_w, cap_stride - 1);
}

static void maybe_paint(struct v4l2_buffer *b)
{
	if (b->type != V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE || b->memory != V4L2_MEMORY_DMABUF ||
	    !b->m.planes || b->length < 1 || cap_stride <= vis_w || vis_w <= 0)
		return;
	struct stat st;
	int dmafd = b->m.planes[0].m.fd;
	if (fstat(dmafd, &st))
		return;
	for (int i = 0; i < ndone; i++)
		if (done_ino[i] == st.st_ino)
			return;
	paint(dmafd);
	if (ndone < MAXBUF)
		done_ino[ndone++] = st.st_ino;
}

int ioctl(int fd, unsigned long req, ...)
{
	va_list ap;
	va_start(ap, req);
	void *arg = va_arg(ap, void *);
	va_end(ap);

	if (req == VIDIOC_QBUF)
		maybe_paint(arg); // before the decoder owns the buffer
	else if (req == DRM_IOCTL_PRIME_HANDLE_TO_FD_)
		((struct drm_prime_handle_ *)arg)->flags |= O_RDWR;

	long r = real_ioctl(fd, req, arg);
	if (r < 0)
		return r;

	if (req == VIDIOC_S_FMT || req == VIDIOC_G_FMT) {
		struct v4l2_format *f = arg;
		if (f->type == V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE &&
		    f->fmt.pix_mp.pixelformat == V4L2_PIX_FMT_NV12 && f->fmt.pix_mp.num_planes == 1) {
			cap_w = f->fmt.pix_mp.width;
			cap_h = f->fmt.pix_mp.height;
			cap_stride = f->fmt.pix_mp.plane_fmt[0].bytesperline;
			vis_w = cap_w;
			vis_h = cap_h;
			ndone = 0;
			query_visible(fd);
		}
	} else if (req == VIDIOC_STREAMON) {
		if (cap_w && *(int *)arg == V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE)
			query_visible(fd);
	}
	return r;
}
