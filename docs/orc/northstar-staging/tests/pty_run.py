#!/usr/bin/env python3
"""在伪终端里运行命令，并发送一行输入；用来测试只允许交互运行的 northstar 子命令。

用法：pty_run.py <输入行> <命令> [参数...]
输出子进程在终端里打印的全部内容，退出码与子进程相同。
"""
import os
import pty
import sys
import time


def main() -> int:
    line, argv = sys.argv[1], sys.argv[2:]
    pid, fd = pty.fork()
    if pid == 0:
        os.execvp(argv[0], argv)
    time.sleep(0.3)
    os.write(fd, (line + "\n").encode())
    out = b""
    while True:
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            break
        if not chunk:
            break
        out += chunk
    _, status = os.waitpid(pid, 0)
    sys.stdout.write(out.decode(errors="replace"))
    return os.waitstatus_to_exitcode(status)


if __name__ == "__main__":
    sys.exit(main())
