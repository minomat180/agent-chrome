"""A thin Python client over the agent-chrome CLI.

Every method runs one ``agent-chrome`` call and returns its text output: the
same report an agent reads in the shell, including what changed on the page.
There is no protocol of its own to drift out of sync with the CLI.
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path
from typing import Iterable, List, Mapping, Optional, Sequence, Union

from . import _paths

PathLike = Union[str, "os.PathLike[str]"]


class AgentChromeError(RuntimeError):
    """A failed agent-chrome call.

    ``message`` and ``hint`` are what the CLI printed; ``output`` holds any
    stdout (for ``run``, the commands that ran before the failing one).
    """

    def __init__(self, message: str, hint: str = "", output: str = "", returncode: int = 1, args: Sequence[str] = ()):
        super().__init__(message + ("\nhint: " + hint if hint else ""))
        self.message = message
        self.hint = hint
        self.output = output
        self.returncode = returncode
        self.command = list(args)


def _parse_error(stderr: str) -> "tuple[str, str]":
    message, hint = [], []
    for line in stderr.strip().splitlines():
        if line.startswith("hint: "):
            hint.append(line[6:])
        elif line.startswith("error: ") and not message:
            message.append(line[7:])
        else:
            (hint if hint else message).append(line)
    return "\n".join(message) or "agent-chrome failed", "\n".join(hint)


class AgentChrome:
    """Drive the agent Chrome on ``127.0.0.1:port`` from Python.

    ``session`` names this caller's tab. Leave it unset to use
    ``AGENT_CHROME_SESSION`` or ``CLAUDE_CODE_SESSION_ID`` like the CLI does;
    give each independent plugin or worker its own value so they do not share
    a tab.

    >>> b = AgentChrome(session="my-plugin")
    >>> print(b.open("example.com"))
    >>> b.click("text=Learn more")
    """

    def __init__(
        self,
        session: Optional[str] = None,
        port: Optional[int] = None,
        quiet: bool = False,
        timeout: Optional[float] = 120,
        env: Optional[Mapping[str, str]] = None,
    ):
        self.session = session
        self.port = port
        self.quiet = quiet
        self.timeout = timeout
        self.env = dict(env) if env is not None else None

    # -- plumbing ----------------------------------------------------------

    def _global_flags(self) -> List[str]:
        flags: List[str] = []
        if self.port is not None:
            flags += ["--port", str(self.port)]
        if self.session is not None:
            flags += ["--session", self.session]
        if self.quiet:
            flags.append("-q")
        return flags

    def call(self, *args: object, stdin: Optional[str] = None, accept: bool = False, prompt: Optional[str] = None) -> str:
        """Run ``agent-chrome <args...>`` and return stdout.

        Raises :class:`AgentChromeError` when the CLI exits non-zero.
        ``accept``/``prompt`` answer a confirm()/prompt() dialog with yes.
        """
        flags = self._global_flags()
        if prompt is not None:
            flags += ["--prompt", prompt]
        elif accept:
            flags.append("--accept")
        argv = [_paths.node(), str(_paths.script("agent-chrome"))] + flags + [str(a) for a in args]
        env = None
        if self.env is not None:
            env = dict(os.environ)
            env.update(self.env)
        proc = subprocess.run(
            argv,
            input=stdin if stdin is not None else "",
            capture_output=True,
            text=True,
            timeout=self.timeout,
            env=env,
        )
        if proc.returncode != 0:
            message, hint = _parse_error(proc.stderr)
            if not proc.stderr.strip() and proc.stdout:
                # `run` reports its failing line on stdout
                message = "a command in the batch failed"
            raise AgentChromeError(message, hint, proc.stdout, proc.returncode, argv[2:])
        return proc.stdout.rstrip("\n")

    __call__ = call

    @staticmethod
    def _opt(name: str, value: object) -> List[str]:
        return [] if value is None or value is False else ([name] if value is True else [name, str(value)])

    # -- navigation --------------------------------------------------------

    def open(self, url: str) -> str:
        return self.call("open", url)

    def back(self) -> str:
        return self.call("back")

    def forward(self) -> str:
        return self.call("forward")

    def reload(self) -> str:
        return self.call("reload")

    # -- reading -----------------------------------------------------------

    def snap(self, find: Optional[str] = None, text: bool = False, max: Optional[int] = None) -> str:
        return self.call("snap", *self._opt("--find", find), *self._opt("-a", text), *self._opt("--max", max))

    def text(self, target: Optional[str] = None, max: Optional[int] = None) -> str:
        return self.call("text", *([target] if target else []), *self._opt("--max", max))

    def read(
        self,
        url: Optional[str] = None,
        filter: Optional[str] = None,
        outline: bool = False,
        links: bool = False,
        max: Optional[int] = None,
    ) -> str:
        return self.call(
            "read",
            *([url] if url else []),
            *self._opt("--filter", filter),
            *self._opt("--outline", outline),
            *self._opt("--links", links),
            *self._opt("--max", max),
        )

    def html(self, target: Optional[str] = None, max: Optional[int] = None) -> str:
        return self.call("html", *([target] if target else []), *self._opt("--max", max))

    def eval(self, js: str, main: bool = False) -> str:
        """Evaluate JavaScript (isolated world; ``main=True`` for page globals)."""
        return self.call("eval", *self._opt("--main", main), "-", stdin=js)

    def url(self) -> str:
        return self.call("get", "url")

    def title(self) -> str:
        return self.call("get", "title")

    def value(self, target: str) -> str:
        return self.call("get", "value", target)

    def attr(self, target: str, name: str) -> str:
        return self.call("get", "attr", target, name)

    def count(self, css: str) -> int:
        return int(self.call("get", "count", css).split()[0])

    def shot(self, file: Optional[PathLike] = None, full: bool = False, element: Optional[str] = None) -> Path:
        """Save a screenshot and return its path."""
        if file is None:
            import tempfile
            import time

            folder = Path(tempfile.gettempdir()) / "agent-chrome"
            file = folder / ("shot-%s-%d.png" % (time.strftime("%Y%m%dT%H%M%S"), os.getpid()))
        path = Path(os.fspath(file)).expanduser().resolve()
        self.call("shot", str(path), *self._opt("--full", full), *self._opt("--el", element))
        return path

    # -- acting ------------------------------------------------------------

    def click(self, target: str, force: bool = False, double: bool = False, right: bool = False, accept: bool = False, prompt: Optional[str] = None) -> str:
        return self.call(
            "click", target, *self._opt("--force", force), *self._opt("--double", double), *self._opt("--right", right),
            accept=accept, prompt=prompt,
        )

    def fill(self, target: str, text: str) -> str:
        return self.call("fill", target, text)

    def type(self, text: str, keys: bool = False) -> str:
        return self.call("type", *self._opt("--keys", keys), text)

    def press(self, key: str, accept: bool = False, prompt: Optional[str] = None) -> str:
        return self.call("press", key, accept=accept, prompt=prompt)

    def select(self, target: str, option: str) -> str:
        return self.call("select", target, option)

    def check(self, target: str) -> str:
        return self.call("check", target)

    def uncheck(self, target: str) -> str:
        return self.call("uncheck", target)

    def hover(self, target: str) -> str:
        return self.call("hover", target)

    def scroll(self, where: str = "down", pages: Optional[float] = None) -> str:
        return self.call("scroll", where, *([pages] if pages is not None else []))

    def upload(self, target: str, *files: PathLike) -> str:
        return self.call("upload", target, *[os.fspath(f) for f in files])

    def download(self, target: str, to: Optional[PathLike] = None) -> str:
        return self.call("download", target, *self._opt("--to", os.fspath(to) if to else None))

    def secret(self, target: str, value: str) -> str:
        """Type ``value`` into a field through stdin; it never reaches argv or the report."""
        return self.call("secret", target, stdin=value)

    # -- waiting -----------------------------------------------------------

    def wait(self, kind: Union[str, int], arg: Optional[str] = None, timeout: Optional[int] = None) -> str:
        """``wait(500)``, ``wait("text", "Saved")``, ``wait("gone", ...)``, ``wait("sel", css)``, ``wait("url", part)``, ``wait("load")``."""
        return self.call("wait", kind, *([arg] if arg is not None else []), *self._opt("--timeout", timeout))

    # -- tabs and session --------------------------------------------------

    def tabs(self) -> str:
        return self.call("tabs")

    def tab_new(self, url: Optional[str] = None) -> str:
        return self.call("tab", "new", *([url] if url else []))

    def tab_use(self, tab_id: str) -> str:
        return self.call("tab", "use", tab_id)

    def tab_close(self, tab_id: Optional[str] = None) -> str:
        return self.call("tab", "close", *([tab_id] if tab_id else []))

    def status(self) -> str:
        return self.call("status")

    def close(self) -> str:
        """Close this session's tabs."""
        return self.call("close")

    def run(self, commands: Union[str, Iterable[str]]) -> str:
        """Run a batch, one command per line; stops at the first error."""
        script = commands if isinstance(commands, str) else "\n".join(commands)
        return self.call("run", stdin=script)

    def cdp(self, method: str, params: Optional[str] = None, browser: bool = False) -> str:
        return self.call("cdp", method, *([params] if params else []), *self._opt("--browser", browser))

    # -- context manager: close the session's tabs on exit -----------------

    def __enter__(self) -> "AgentChrome":
        return self

    def __exit__(self, *exc: object) -> None:
        try:
            self.close()
        except AgentChromeError:
            pass


def ctl(*args: object, timeout: Optional[float] = 300) -> str:
    """Run ``agent-chrome-ctl <args...>`` (start, stop, status, update, login, background ...)."""
    import shutil

    bash = shutil.which("bash")
    if not bash:
        raise FileNotFoundError("agent-chrome-ctl needs bash on PATH")
    argv = [bash, str(_paths.script("agent-chrome-ctl"))] + [str(a) for a in args]
    proc = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL)
    if proc.returncode != 0:
        message, hint = _parse_error(proc.stderr or proc.stdout)
        raise AgentChromeError(message, hint, proc.stdout, proc.returncode, argv[1:])
    return proc.stdout.rstrip("\n")
