"""Read selected members out of a remote ZIP over HTTP range requests.

CelebAMask-HQ ships as one 3.1 GB zip. The Hugging Face CDN answers `Range:`
with 206, so the central directory (last few MB) plus the ~10 members we actually
need is a few MB of traffic instead of 3.1 GB. Used by fetch_celebamaskhq.py.
"""
import io, os, subprocess, sys, zipfile


class HTTPRangeFile(io.RawIOBase):
    def __init__(self, url, size=None):
        self.url = url
        self.pos = 0
        self.size = size if size is not None else self._probe_size()

    def _probe_size(self):
        out = subprocess.run(
            ["curl", "-sIL", "--max-time", "60", self.url],
            capture_output=True, text=True, check=True).stdout
        for line in out.splitlines():
            if line.lower().startswith("x-linked-size:"):
                return int(line.split(":")[1].strip())
        for line in reversed(out.splitlines()):
            if line.lower().startswith("content-length:"):
                return int(line.split(":")[1].strip())
        raise RuntimeError("no size")

    def readable(self): return True
    def seekable(self): return True

    def seek(self, offset, whence=0):
        if whence == 0: self.pos = offset
        elif whence == 1: self.pos += offset
        else: self.pos = self.size + offset
        return self.pos

    def tell(self): return self.pos

    def read(self, n=-1):
        if n is None or n < 0:
            n = self.size - self.pos
        if n == 0 or self.pos >= self.size:
            return b""
        end = min(self.size, self.pos + n) - 1
        out = subprocess.run(
            ["curl", "-sL", "--max-time", "300", "--retry", "3",
             "-r", f"{self.pos}-{end}", self.url],
            capture_output=True, check=True).stdout
        self.pos += len(out)
        return out

    def readinto(self, b):
        data = self.read(len(b))
        b[:len(data)] = data
        return len(data)


if __name__ == "__main__":
    url, listfile, outdir = sys.argv[1], sys.argv[2], sys.argv[3]
    wanted = [l.strip() for l in open(listfile) if l.strip()]
    raw = HTTPRangeFile(url)
    zf = zipfile.ZipFile(io.BufferedReader(raw, buffer_size=1 << 20))
    names = set(zf.namelist())
    if wanted == ["--list"]:
        print(len(names))
        for n in list(sorted(names))[:50]:
            print(n)
        sys.exit(0)
    os.makedirs(outdir, exist_ok=True)
    for w in wanted:
        if w not in names:
            print("MISSING", w); continue
        data = zf.read(w)
        dest = os.path.join(outdir, os.path.basename(w))
        with open(dest, "wb") as f:
            f.write(data)
        print("ok", w, len(data))
