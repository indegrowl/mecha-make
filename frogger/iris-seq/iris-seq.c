// SPDX-License-Identifier: MIT
/*
 * iris-seq: drive the Iris V4L2 stateful decoder through client sequences
 * (seek, drain, restart, double stop, resolution change) and check every
 * decoded frame against a per-frame Adler-32 reference (ffmpeg framecrc of
 * the packed NV12 picture), so each output frame is identified by index.
 *
 * Usage: iris-seq <h264|hevc|vp9> <stream> <ref.adler> <op>...
 *   stream: Annex-B with an AUD before every access unit (h264/hevc) or IVF (vp9)
 *   ops:
 *     play:N    feed access units in order until N more frames came out
 *     feed:N    queue N more access units without waiting for frames
 *     drain     V4L2_DEC_CMD_STOP, then dequeue until the LAST buffer
 *     stop      V4L2_DEC_CMD_STOP only
 *     start     V4L2_DEC_CMD_START
 *     seek:K    STREAMOFF/STREAMON OUTPUT, continue from access unit K
 *     seekc:K   as seek:K, and STREAMOFF/STREAMON CAPTURE with all buffers requeued
 *     wait:MS   keep dequeuing for MS milliseconds
 *     reopen    close the device and start a new session (input position kept)
 *
 * Prints one line per op and a SUMMARY line. Exit 0, 1 on a check failure
 * reported by the ops, 2 on setup errors, 3 when the decoder hangs (no
 * progress for 3 s while frames are expected).
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include <linux/videodev2.h>

#define NUM_OUT 16
#define MAX_CAP 32
#define HANG_MS 3000

struct buf { void *mem; size_t len; int queued; };

static int fd = -1;
static uint32_t codec;
static struct buf out[NUM_OUT], cap[MAX_CAP];
static int ncap, cap_on, out_on;
static uint32_t bpl, fmt_h, vis_w, vis_h;

/* input access units */
static unsigned char *data;
static size_t *au_off, *au_len;
static int nau, pos;

/* reference */
static uint32_t *ref;
static int nref;

/* counters for the current op and in total */
static int op_frames, op_lasts, op_errors, op_eos, op_src;
static int tot_frames, tot_matched, tot_lasts, tot_errors, tot_eos, tot_src;
static int last_idx = -1, last_flag_seen, resize_pending;
static char seq[4096];
static size_t seqlen;

static void die(int code, const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fputc('\n', stderr);
	exit(code);
}

static long now_ms(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static uint32_t adler32(uint32_t a, const unsigned char *p, size_t n)
{
	uint32_t s1 = a & 0xffff, s2 = a >> 16;
	while (n) {
		size_t k = n < 3800 ? n : 3800;
		n -= k;
		while (k--) {
			s1 += *p++;
			s2 += s1;
		}
		s1 %= 65521;
		s2 %= 65521;
	}
	return (s2 << 16) | s1;
}

static void seq_add(const char *fmt, ...)
{
	va_list ap;
	if (seqlen > sizeof(seq) - 64)
		return;
	va_start(ap, fmt);
	seqlen += vsnprintf(seq + seqlen, sizeof(seq) - seqlen, fmt, ap);
	va_end(ap);
}

/* compact "a-b,c" list of the reference indexes that came out */
static int run_start = -2, run_end = -2, unknown_run;
static void seq_flush_run(void)
{
	if (run_start == -2)
		return;
	if (run_start == -1)
		seq_add("?x%d", unknown_run);
	else if (run_start == run_end)
		seq_add("%d", run_start);
	else
		seq_add("%d-%d", run_start, run_end);
	seq_add(",");
	run_start = run_end = -2;
}
static void seq_frame(int idx)
{
	if (idx >= 0 && run_start >= 0 && idx == run_end + 1) {
		run_end = idx;
		return;
	}
	if (idx < 0 && run_start == -1) {
		unknown_run++;
		return;
	}
	seq_flush_run();
	run_start = run_end = idx;
	unknown_run = 1;
}

static void load_input(const char *path)
{
	struct stat st;
	int f = open(path, O_RDONLY);
	if (f < 0 || fstat(f, &st))
		die(2, "open %s: %s", path, strerror(errno));
	data = malloc(st.st_size);
	if (read(f, data, st.st_size) != st.st_size)
		die(2, "read %s", path);
	close(f);
	au_off = calloc(st.st_size / 8 + 1, sizeof(size_t));
	au_len = calloc(st.st_size / 8 + 1, sizeof(size_t));

	if (codec == V4L2_PIX_FMT_VP9) {
		size_t p = 32;
		while (p + 12 <= (size_t)st.st_size) {
			uint32_t sz = data[p] | data[p + 1] << 8 | data[p + 2] << 16 | (uint32_t)data[p + 3] << 24;
			au_off[nau] = p + 12;
			au_len[nau++] = sz;
			p += 12 + sz;
		}
		return;
	}

	/* split on access unit delimiters: h264 nal type 9, hevc nal type 35 */
	for (size_t p = 0; p + 6 <= (size_t)st.st_size; p++) {
		if (data[p] || data[p + 1] || data[p + 2] || data[p + 3] != 1)
			continue;
		int aud = codec == V4L2_PIX_FMT_H264 ? (data[p + 4] & 0x1f) == 9
						     : ((data[p + 4] >> 1) & 0x3f) == 35;
		if (!aud)
			continue;
		if (nau)
			au_len[nau - 1] = p - au_off[nau - 1];
		au_off[nau++] = p;
	}
	if (nau)
		au_len[nau - 1] = st.st_size - au_off[nau - 1];
}

static void load_ref(const char *path)
{
	FILE *f = fopen(path, "r");
	char line[64];
	if (!f)
		die(2, "open %s", path);
	ref = calloc(100000, sizeof(uint32_t));
	while (fgets(line, sizeof(line), f) && nref < 100000)
		ref[nref++] = strtoul(line, NULL, 16);
	fclose(f);
}

static int ref_index(uint32_t a)
{
	/* prefer the frame after the previous one, else search */
	if (last_idx + 1 < nref && last_idx >= -1 && ref[last_idx + 1] == a)
		return last_idx + 1;
	for (int i = 0; i < nref; i++)
		if (ref[i] == a)
			return i;
	return -1;
}

static void xioctl(unsigned long req, void *arg, const char *name)
{
	if (ioctl(fd, req, arg) < 0)
		die(2, "%s: %s", name, strerror(errno));
}

static int open_decoder(void)
{
	DIR *d = opendir("/dev");
	struct dirent *e;
	while (d && (e = readdir(d))) {
		char p[300];
		struct v4l2_capability c;
		if (strncmp(e->d_name, "video", 5))
			continue;
		snprintf(p, sizeof(p), "/dev/%s", e->d_name);
		int f = open(p, O_RDWR | O_NONBLOCK);
		if (f < 0)
			continue;
		if (!ioctl(f, VIDIOC_QUERYCAP, &c) && strstr((char *)c.card, "Iris Decoder")) {
			closedir(d);
			return f;
		}
		close(f);
	}
	if (d)
		closedir(d);
	return -1;
}

static void queue_out(int i, int au)
{
	struct v4l2_plane pl = { 0 };
	struct v4l2_buffer b = { 0 };
	memcpy(out[i].mem, data + au_off[au], au_len[au]);
	pl.bytesused = au_len[au];
	b.type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
	b.memory = V4L2_MEMORY_MMAP;
	b.index = i;
	b.m.planes = &pl;
	b.length = 1;
	b.timestamp.tv_sec = au / 1000;
	b.timestamp.tv_usec = (au % 1000) * 1000;
	xioctl(VIDIOC_QBUF, &b, "QBUF output");
	out[i].queued = 1;
}

static void queue_cap(int i)
{
	struct v4l2_plane pl = { 0 };
	struct v4l2_buffer b = { 0 };
	b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
	b.memory = V4L2_MEMORY_MMAP;
	b.index = i;
	b.m.planes = &pl;
	b.length = 1;
	if (ioctl(fd, VIDIOC_QBUF, &b) == 0)
		cap[i].queued = 1;
}

static void setup_capture(void)
{
	struct v4l2_format f = { .type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE };
	struct v4l2_selection s = { .type = V4L2_BUF_TYPE_VIDEO_CAPTURE, .target = V4L2_SEL_TGT_COMPOSE };
	struct v4l2_requestbuffers rb = { 0 };
	struct v4l2_control ctl = { .id = V4L2_CID_MIN_BUFFERS_FOR_CAPTURE };

	/* the decoder's own format (NV12): S_FMT would reset the crop to the
	 * padded size */
	xioctl(VIDIOC_G_FMT, &f, "G_FMT capture");
	if (f.fmt.pix_mp.pixelformat != V4L2_PIX_FMT_NV12)
		die(2, "capture format is not NV12");
	bpl = f.fmt.pix_mp.plane_fmt[0].bytesperline;
	fmt_h = f.fmt.pix_mp.height;
	vis_w = f.fmt.pix_mp.width;
	vis_h = f.fmt.pix_mp.height;
	if (!ioctl(fd, VIDIOC_G_SELECTION, &s) && s.r.width && s.r.height) {
		vis_w = s.r.width;
		vis_h = s.r.height;
	}
	ioctl(fd, VIDIOC_G_CTRL, &ctl);
	rb.count = ctl.value + 4 > 20 ? ctl.value + 4 : 20; /* as ffmpeg */
	if (rb.count > MAX_CAP)
		rb.count = MAX_CAP;
	rb.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
	rb.memory = V4L2_MEMORY_MMAP;
	xioctl(VIDIOC_REQBUFS, &rb, "REQBUFS capture");
	ncap = rb.count;
	for (int i = 0; i < ncap; i++) {
		struct v4l2_plane pl = { 0 };
		struct v4l2_buffer b = { .type = rb.type, .memory = rb.memory, .index = i, .m.planes = &pl, .length = 1 };
		xioctl(VIDIOC_QUERYBUF, &b, "QUERYBUF capture");
		cap[i].len = pl.length;
		cap[i].mem = mmap(NULL, pl.length, PROT_READ, MAP_SHARED, fd, pl.m.mem_offset);
		if (cap[i].mem == MAP_FAILED)
			die(2, "mmap capture");
		queue_cap(i);
	}
	int t = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
	xioctl(VIDIOC_STREAMON, &t, "STREAMON capture");
	cap_on = 1;
	printf("  capture %ux%u (buffer %ux%u, bpl %u) x%d\n", vis_w, vis_h, f.fmt.pix_mp.width, fmt_h, bpl, ncap);
}

static void release_capture(void)
{
	int t = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
	struct v4l2_requestbuffers rb = { .type = t, .memory = V4L2_MEMORY_MMAP };
	if (cap_on)
		ioctl(fd, VIDIOC_STREAMOFF, &t);
	cap_on = 0;
	for (int i = 0; i < ncap; i++) {
		munmap(cap[i].mem, cap[i].len);
		cap[i].queued = 0;
	}
	ncap = 0;
	ioctl(fd, VIDIOC_REQBUFS, &rb);
}

static void open_session(void)
{
	struct v4l2_format f = { .type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE };
	struct v4l2_requestbuffers rb = { 0 };
	struct v4l2_event_subscription sub = { 0 };
	int t = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;

	fd = open_decoder();
	if (fd < 0)
		die(2, "no Iris decoder node");
	f.fmt.pix_mp.pixelformat = codec;
	f.fmt.pix_mp.width = 1920;
	f.fmt.pix_mp.height = 1080;
	f.fmt.pix_mp.num_planes = 1;
	f.fmt.pix_mp.plane_fmt[0].sizeimage = 4 << 20;
	xioctl(VIDIOC_S_FMT, &f, "S_FMT output");
	sub.type = V4L2_EVENT_SOURCE_CHANGE;
	xioctl(VIDIOC_SUBSCRIBE_EVENT, &sub, "SUBSCRIBE source change");
	sub.type = V4L2_EVENT_EOS;
	xioctl(VIDIOC_SUBSCRIBE_EVENT, &sub, "SUBSCRIBE eos");
	rb.count = NUM_OUT;
	rb.type = t;
	rb.memory = V4L2_MEMORY_MMAP;
	xioctl(VIDIOC_REQBUFS, &rb, "REQBUFS output");
	for (int i = 0; i < NUM_OUT; i++) {
		struct v4l2_plane pl = { 0 };
		struct v4l2_buffer b = { .type = t, .memory = V4L2_MEMORY_MMAP, .index = i, .m.planes = &pl, .length = 1 };
		xioctl(VIDIOC_QUERYBUF, &b, "QUERYBUF output");
		out[i].len = pl.length;
		out[i].mem = mmap(NULL, pl.length, PROT_READ | PROT_WRITE, MAP_SHARED, fd, pl.m.mem_offset);
		if (out[i].mem == MAP_FAILED)
			die(2, "mmap output");
		out[i].queued = 0;
	}
	xioctl(VIDIOC_STREAMON, &t, "STREAMON output");
	out_on = 1;
	last_flag_seen = resize_pending = 0;
}

static void close_session(void)
{
	release_capture();
	for (int i = 0; i < NUM_OUT; i++)
		munmap(out[i].mem, out[i].len);
	close(fd);
	fd = -1;
	out_on = 0;
}

static int free_out(void)
{
	for (int i = 0; i < NUM_OUT; i++)
		if (!out[i].queued)
			return i;
	return -1;
}

/* one round of dequeuing; returns 1 if anything happened */
static int service(int timeout)
{
	struct pollfd p = { .fd = fd, .events = POLLIN | POLLOUT | POLLPRI };
	int any = 0;

	if (poll(&p, 1, timeout) <= 0)
		return 0;
	if (p.revents & POLLERR)
		any = -1;

	for (;;) {
		struct v4l2_event ev;
		if (ioctl(fd, VIDIOC_DQEVENT, &ev))
			break;
		any = 1;
		if (ev.type == V4L2_EVENT_EOS) {
			op_eos++;
		} else if (ev.type == V4L2_EVENT_SOURCE_CHANGE) {
			op_src++;
			if (cap_on)
				resize_pending = 1; /* reallocate after the LAST buffer */
			else
				setup_capture();
		}
	}

	for (;;) {
		struct v4l2_plane pl = { 0 };
		struct v4l2_buffer b = { .type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE, .memory = V4L2_MEMORY_MMAP, .m.planes = &pl, .length = 1 };
		if (ioctl(fd, VIDIOC_DQBUF, &b))
			break;
		out[b.index].queued = 0;
		any = 1;
	}

	while (cap_on) {
		struct v4l2_plane pl = { 0 };
		struct v4l2_buffer b = { .type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE, .memory = V4L2_MEMORY_MMAP, .m.planes = &pl, .length = 1 };
		if (ioctl(fd, VIDIOC_DQBUF, &b))
			break;
		any = 1;
		cap[b.index].queued = 0;
		if (b.flags & V4L2_BUF_FLAG_ERROR)
			op_errors++;
		if (pl.bytesused && !(b.flags & V4L2_BUF_FLAG_ERROR)) {
			const unsigned char *m = cap[b.index].mem;
			uint32_t a = 0; /* ffmpeg framecrc seeds Adler-32 with 0 */
			for (uint32_t r = 0; r < vis_h; r++)
				a = adler32(a, m + r * bpl, vis_w);
			for (uint32_t r = 0; r < vis_h / 2; r++)
				a = adler32(a, m + bpl * fmt_h + r * bpl, vis_w);
			int idx = ref_index(a);
			op_frames++;
			tot_frames++;
			if (idx >= 0) {
				tot_matched++;
				last_idx = idx;
			}
			seq_frame(idx);
		}
		if (b.flags & V4L2_BUF_FLAG_LAST) {
			op_lasts++;
			last_flag_seen = 1;
			if (resize_pending) {
				resize_pending = 0;
				release_capture();
				setup_capture();
				last_flag_seen = 0;
				continue;
			}
			break; /* the queue is stopped until START or STREAMON */
		}
		queue_cap(b.index);
	}
	return any;
}

/* keep the output queue full and dequeue until cond() or a hang */
static int run(int (*cond)(void), int feed)
{
	long last = now_ms();
	while (!cond()) {
		int i;
		while (feed && pos < nau && (i = free_out()) >= 0 && out_on)
			queue_out(i, pos++);
		int r = service(100);
		if (r < 0)
			return -1;
		if (r)
			last = now_ms();
		else if (now_ms() - last > HANG_MS)
			/* all input sent: the decoder keeps its last frames until a drain */
			return feed && pos >= nau ? 0 : 3;
	}
	return 0;
}

static int want_frames;
static int c_frames(void) { return op_frames >= want_frames; }
static int c_last(void) { return last_flag_seen; }
static long wait_until;
static int c_time(void) { return now_ms() >= wait_until; }

static int dec_cmd(uint32_t cmd)
{
	struct v4l2_decoder_cmd c = { .cmd = cmd };
	return ioctl(fd, VIDIOC_DECODER_CMD, &c) ? -errno : 0;
}

static void stream(uint32_t type, int on)
{
	int t = type;
	ioctl(fd, on ? VIDIOC_STREAMON : VIDIOC_STREAMOFF, &t);
}

int main(int argc, char **argv)
{
	int hang = 0, rc = 0;

	setvbuf(stdout, NULL, _IOLBF, 0);
	if (argc < 5)
		die(2, "usage: iris-seq <h264|hevc|vp9> <stream> <ref.adler> <op>...");
	codec = !strcmp(argv[1], "h264") ? V4L2_PIX_FMT_H264 :
		!strcmp(argv[1], "hevc") ? V4L2_PIX_FMT_HEVC :
		!strcmp(argv[1], "vp9") ? V4L2_PIX_FMT_VP9 : 0;
	if (!codec)
		die(2, "codec must be h264, hevc or vp9");
	load_input(argv[2]);
	load_ref(argv[3]);
	printf("input %d access units, reference %d frames\n", nau, nref);
	open_session();

	for (int a = 4; a < argc && !hang; a++) {
		char *op = argv[a], *arg = strchr(op, ':');
		int n = arg ? atoi(arg + 1) : 0, r = 0;

		op_frames = op_lasts = op_errors = op_eos = op_src = 0;
		seqlen = 0;
		seq[0] = 0;
		run_start = run_end = -2;

		if (!strncmp(op, "play:", 5)) {
			want_frames = n;
			r = run(c_frames, 1);
		} else if (!strncmp(op, "feed:", 5)) {
			for (int k = 0; k < n && pos < nau;) {
				int i = free_out();
				if (i >= 0) {
					queue_out(i, pos++);
					k++;
				} else if (!service(HANG_MS)) {
					r = 3;
					break;
				}
			}
		} else if (!strcmp(op, "drain")) {
			int e = dec_cmd(V4L2_DEC_CMD_STOP);
			if (e)
				printf("  STOP: %s\n", strerror(-e));
			r = e ? 0 : run(c_last, 0);
		} else if (!strcmp(op, "stop")) {
			int e = dec_cmd(V4L2_DEC_CMD_STOP);
			printf("  STOP: %s\n", e ? strerror(-e) : "ok");
		} else if (!strcmp(op, "start")) {
			int e = dec_cmd(V4L2_DEC_CMD_START);
			printf("  START: %s\n", e ? strerror(-e) : "ok");
			if (!e) {
				last_flag_seen = 0;
				for (int i = 0; i < ncap; i++)
					if (!cap[i].queued)
						queue_cap(i);
			}
		} else if (!strncmp(op, "seek:", 5) || !strncmp(op, "seekc:", 6)) {
			int withcap = op[4] == 'c';
			stream(V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE, 0);
			for (int i = 0; i < NUM_OUT; i++)
				out[i].queued = 0;
			if (withcap && cap_on) {
				stream(V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE, 0);
				for (int i = 0; i < ncap; i++)
					cap[i].queued = 0;
			}
			stream(V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE, 1);
			if (withcap && ncap) {
				stream(V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE, 1);
				for (int i = 0; i < ncap; i++)
					queue_cap(i);
			}
			last_flag_seen = 0;
			last_idx = n - 1;
			pos = n;
		} else if (!strncmp(op, "wait:", 5)) {
			wait_until = now_ms() + n;
			r = run(c_time, 0);
			if (r == 3)
				r = 0; /* silence is fine when only waiting */
		} else if (!strcmp(op, "reopen")) {
			close_session();
			open_session();
		} else {
			die(2, "unknown op %s", op);
		}

		seq_flush_run();
		tot_lasts += op_lasts;
		tot_errors += op_errors;
		tot_eos += op_eos;
		tot_src += op_src;
		if (r == 3)
			hang = 1;
		if (r < 0)
			rc = 1;
		if (seqlen)
			seq[seqlen - 1] = 0;
		printf("OP %-10s frames=%d last=%d err=%d eos=%d srcchg=%d%s%s [%s]\n", op,
		       op_frames, op_lasts, op_errors, op_eos, op_src,
		       r == 3 ? " HANG" : "", r < 0 ? " POLLERR" : "", seq);
	}
	printf("SUMMARY frames=%d matched=%d last=%d err=%d eos=%d srcchg=%d hang=%d\n",
	       tot_frames, tot_matched, tot_lasts, tot_errors, tot_eos, tot_src, hang);
	return hang ? 3 : rc;
}
