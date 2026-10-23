// Checks the streaming_client padding shim (frogger/steam/sc-padfix.c) with a
// fake V4L2 device: memfd buffers stand in for the decoder's dmabufs.
#define _GNU_SOURCE
#include <stdint.h>
#include <stdio.h>
#include <sys/mman.h>
#include <unistd.h>

long test_real_ioctl(int fd, unsigned long req, void *arg);
#define SC_PADFIX_TEST
#include "../../frogger/steam/sc-padfix.c"

static int fail;
#define CHECK(name, cond) do { if (cond) printf("ok   %s\n", name); \
	else { printf("FAIL %s\n", name); fail = 1; } } while (0)

enum { W = 64, H = 32, STRIDE = 64 };
static int sel_w = 42, sel_h = 26;

long test_real_ioctl(int fd, unsigned long req, void *arg)
{
	(void)fd;
	if (req == VIDIOC_G_SELECTION) {
		struct v4l2_selection *s = arg;
		s->r.left = s->r.top = 0;
		s->r.width = sel_w;
		s->r.height = sel_h;
	}
	return 0;
}

// A frame whose visible area is a pattern and whose padding is zero (green).
static void decode(uint8_t *p, int vw, int vh)
{
	memset(p, 0, STRIDE * H * 3 / 2);
	for (int y = 0; y < vh; y++)
		for (int x = 0; x < vw; x++)
			p[y * STRIDE + x] = 20 + x + y;
	uint8_t *uv = p + STRIDE * H;
	for (int y = 0; y < (vh + 1) / 2; y++)
		for (int x = 0; x < ((vw + 1) & ~1); x++)
			uv[y * STRIDE + x] = 100 + x + y;
}

// Every padding sample equals the nearest visible one (edge clamp).
static int clamped(const uint8_t *p, int vw, int vh)
{
	for (int y = 0; y < H; y++)
		for (int x = 0; x < STRIDE; x++) {
			int sy = y < vh ? y : vh - 1, sx = x < vw ? x : vw - 1;
			if (p[y * STRIDE + x] != p[sy * STRIDE + sx])
				return 0;
		}
	const uint8_t *uv = p + STRIDE * H;
	int cw = (vw + 1) & ~1, ch = (vh + 1) / 2;
	for (int y = 0; y < H / 2; y++)
		for (int x = 0; x < STRIDE; x++) {
			int sy = y < ch ? y : ch - 1, sx = x < cw ? x : cw - 2 + (x & 1);
			if (uv[y * STRIDE + x] != uv[sy * STRIDE + sx])
				return 0;
		}
	return 1;
}

static int set_fmt(unsigned long req)
{
	struct v4l2_format f = { .type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE };
	f.fmt.pix_mp.width = W;
	f.fmt.pix_mp.height = H;
	f.fmt.pix_mp.pixelformat = V4L2_PIX_FMT_NV12;
	f.fmt.pix_mp.num_planes = 1;
	f.fmt.pix_mp.plane_fmt[0].bytesperline = STRIDE;
	return ioctl(3, req, &f);
}

static int queue(unsigned long req, int index, int fd)
{
	struct v4l2_plane pl = { .m.fd = fd };
	struct v4l2_buffer b = { .index = index, .type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE,
				 .memory = V4L2_MEMORY_DMABUF, .m.planes = &pl, .length = 1 };
	return ioctl(3, req, &b);
}

static uint8_t *new_buffer(int *fd)
{
	*fd = memfd_create("frame", 0);
	ftruncate(*fd, STRIDE * H * 3 / 2);
	return mmap(NULL, STRIDE * H * 3 / 2, PROT_READ | PROT_WRITE, MAP_SHARED, *fd, 0);
}

int main(void)
{
	static uint8_t frame[STRIDE * H * 3 / 2];
	decode(frame, 42, 26);
	fill_padding(frame, STRIDE, H, 42, 26);
	CHECK("even width: padding repeats the edge", clamped(frame, 42, 26));
	decode(frame, 41, 25);
	fill_padding(frame, STRIDE, H, 41, 25);
	CHECK("odd width and height: padding repeats the edge", clamped(frame, 41, 25));
	decode(frame, W, H);
	fill_padding(frame, STRIDE, H, W, H);
	CHECK("no padding: frame untouched", clamped(frame, W, H) && frame[0] == 20);

	set_fmt(VIDIOC_S_FMT);
	int fd0, fd1;
	uint8_t *b0 = new_buffer(&fd0), *b1 = new_buffer(&fd1);
	queue(VIDIOC_QBUF, 0, fd0);
	queue(VIDIOC_QBUF, 1, fd1);
	close(fd0); // the client closes its fds right after QBUF
	close(fd1);
	decode(b0, 42, 26); // the decoder writes the encoder's (green) padding
	queue(VIDIOC_DQBUF, 0, 99);
	CHECK("decoded frame is fixed at DQBUF", clamped(b0, 42, 26));
	decode(b1, 42, 26);
	set_fmt(VIDIOC_G_FMT); // same format again: buffers stay known
	queue(VIDIOC_DQBUF, 1, 99);
	CHECK("same-size G_FMT keeps buffers", clamped(b1, 42, 26));
	decode(b0, 42, 26);
	queue(VIDIOC_DQBUF, 0, 99);
	CHECK("every frame is fixed, not just the first", clamped(b0, 42, 26));

	sel_w = 40;
	set_fmt(VIDIOC_S_FMT);
	decode(b0, 40, 26);
	queue(VIDIOC_DQBUF, 0, 99);
	CHECK("new format forgets old buffers", b0[40] == 0);

	puts(fail ? "FAILED" : "PASS");
	return fail;
}
