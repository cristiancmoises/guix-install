"""Unprivileged native desktop form. All installation policy lives in core."""

import os
import queue
import shutil
import subprocess
import sys
import threading
from dataclasses import asdict

from . import __version__, core
from .__main__ import option_args
from .i18n import tr, translated_plan


def terminal_command(options, language, theme="dark"):
    command = [
        sys.executable,
        str(core.ROOT / "run.py"),
        "install",
        "--lang",
        language,
        "--theme",
        theme,
        "--hold",
        *option_args(options),
    ]
    for terminal, flags in [
        ("xterm", ["-e"]),
        ("gnome-terminal", ["--wait", "--"]),
        ("konsole", ["-e"]),
        ("xfce4-terminal", ["--disable-server", "--execute"]),
        ("mate-terminal", ["--disable-factory", "--"]),
    ]:
        path = shutil.which(terminal)
        if path:
            return [path, *flags, *command]
    raise core.InstallError(tr("missing_terminal", language))


class InstallerWindow:
    BG = "#080808"
    INK = "#ffffff"
    MUTED = "#c5c5c5"
    GREEN = "#f4c542"
    WHITE = "#151515"

    def __init__(self, root, options, language="en", theme="dark"):
        import tkinter as tk
        from tkinter import ttk

        self.tk, self.ttk, self.root = tk, ttk, root
        self.language = language
        self.theme = theme
        self.values: dict[str, tk.Variable] = {
            key: (
                tk.BooleanVar(value=value)
                if isinstance(value, bool)
                else tk.StringVar(value=value)
            )
            for key, value in asdict(options).items()
            if not isinstance(value, tuple)
        }
        self.kernel_labels = {}
        self.terminal_vars = {
            name: tk.BooleanVar(value=name in options.terminals)
            for name in core.TERMINAL_CHOICES
        }
        self.browser_vars = {
            name: tk.BooleanVar(value=name in options.browsers)
            for name in core.BROWSER_CHOICES
        }
        self.channel_vars = {
            name: tk.BooleanVar(value=name in (options.channels or ()))
            for name in core.channels_catalog.OPTIONAL_NAMES
        }
        self.reviewed = False
        self.child = None
        self.query_running = False
        self.query_results = queue.Queue()
        self.generation = 0
        self.system_fields = []
        root.title("GNU Guix Installer")
        root.geometry("1020x980")
        root.minsize(780, 720)
        self.apply_theme()
        self.build()
        for variable in self.values.values():
            variable.trace_add("write", self.invalidate)
        root.bind("<Control-Return>", lambda event: self.review())
        root.protocol("WM_DELETE_WINDOW", root.destroy)

    def apply_theme(self):
        if self.theme == "light":
            self.BG, self.INK, self.MUTED, self.WHITE = (
                "#ffffff",
                "#080808",
                "#454545",
                "#f3f3f3",
            )
        else:
            self.BG, self.INK, self.MUTED, self.WHITE = (
                "#080808",
                "#ffffff",
                "#c5c5c5",
                "#151515",
            )
        self.SIDEBAR = "#fafafa" if self.theme == "light" else "#000000"
        self.GOLD = "#895e00" if self.theme == "light" else "#f4c542"
        self.ORANGE = "#a54500" if self.theme == "light" else "#ff9c32"
        self.root.configure(bg=self.BG)
        root, ttk = self.root, self.ttk
        style = ttk.Style(root)
        style.theme_use("clam")
        style.configure(
            ".", font=("DejaVu Sans", -14), background=self.BG, foreground=self.INK
        )
        style.configure("TButton", padding=(14, 9))
        style.configure("Accent.TButton", background=self.GREEN, foreground="#080808")
        style.map(
            "Accent.TButton",
            background=[("active", "#ff9c32"), ("disabled", "#6f6241")],
        )
        style.configure("TEntry", fieldbackground=self.WHITE, padding=5)
        style.configure("TCombobox", fieldbackground=self.WHITE, padding=5)
        style.map(
            "TCombobox",
            fieldbackground=[("readonly", self.WHITE)],
            foreground=[("readonly", self.INK)],
        )
        style.map("TRadiobutton", background=[("active", "#292316")])
        style.map("TButton", background=[("active", "#3c2a14")])
        root.option_add("*TCombobox*Listbox.background", self.WHITE)
        root.option_add("*TCombobox*Listbox.foreground", self.INK)

    def change_theme(self, value):
        self.theme = "light" if value == tr("light", self.language) else "dark"
        self.apply_theme()
        self.build()

    def label(self, parent, text, size=10, color=None, **kwargs):
        return self.tk.Label(
            parent,
            text=text,
            bg=parent.cget("bg"),
            fg=color or self.INK,
            font=("DejaVu Sans", -round(size * 1.4)),
            justify="left",
            anchor="w",
            **kwargs,
        )

    def build(self):
        tk, ttk, root = self.tk, self.ttk, self.root
        for widget in root.winfo_children():
            widget.destroy()
        self.system_fields = []
        self.generation += 1
        self.reviewed = False
        side = tk.Frame(root, bg=self.SIDEBAR, width=230)
        side.pack(side="left", fill="y")
        side.pack_propagate(False)
        self.logo = tk.PhotoImage(file=str(core.ROOT / "assets/guix-logo.png"))
        root.iconphoto(True, self.logo)
        tk.Label(side, image=self.logo, bg=self.SIDEBAR, takefocus=False).pack(
            pady=(16, 0)
        )
        self.label(side, "GNU Guix", 23, self.ORANGE).pack(
            anchor="w", padx=28, pady=(0, 8)
        )
        self.label(side, "INSTALLER  /  " + __version__, 10, self.GOLD).pack(
            anchor="w", padx=28
        )
        self.label(side, "01  " + tr("choose", self.language), 10, self.INK).pack(
            anchor="w", padx=24, pady=(48, 14)
        )
        self.label(side, "02  " + tr("settings", self.language), 10, self.INK).pack(
            anchor="w", padx=24, pady=14
        )
        self.label(side, "03  " + tr("review", self.language), 10, self.INK).pack(
            anchor="w", padx=24, pady=14
        )
        safety = tk.Frame(side, bg=self.SIDEBAR)
        safety.pack(side="bottom", fill="x", padx=24, pady=30)
        self.label(
            safety, tr("safety", self.language), 9, self.GOLD, wraplength=185
        ).pack(fill="x")
        self.label(
            safety, tr("safety_body", self.language), 10, self.INK, wraplength=180
        ).pack(fill="x", pady=(12, 0))
        outer = tk.Frame(root, bg=self.BG)
        outer.pack(side="right", fill="both", expand=True)
        canvas = tk.Canvas(outer, bg=self.BG, highlightthickness=0)
        scrollbar = ttk.Scrollbar(outer, orient="vertical", command=canvas.yview)
        scrollbar.pack(side="right", fill="y")
        canvas.pack(side="left", fill="both", expand=True)
        canvas.configure(yscrollcommand=scrollbar.set)
        content = tk.Frame(canvas, bg=self.BG, padx=30, pady=24)
        item = canvas.create_window((0, 0), window=content, anchor="nw")
        content.bind(
            "<Configure>",
            lambda event: canvas.configure(scrollregion=canvas.bbox("all")),
        )
        canvas.bind(
            "<Configure>", lambda event: canvas.itemconfigure(item, width=event.width)
        )
        canvas.bind("<Button-4>", lambda event: canvas.yview_scroll(-3, "units"))
        canvas.bind("<Button-5>", lambda event: canvas.yview_scroll(3, "units"))
        canvas.bind(
            "<MouseWheel>",
            lambda event: canvas.yview_scroll(-int(event.delta / 120), "units"),
        )
        header = tk.Frame(content, bg=self.BG)
        header.pack(fill="x")
        theme_selector = ttk.Combobox(
            header,
            state="readonly",
            values=[tr("dark", self.language), tr("light", self.language)],
            width=16,
        )
        theme_selector.set(tr(self.theme, self.language))
        theme_selector.pack(side="left")
        theme_selector.bind(
            "<<ComboboxSelected>>",
            lambda event: self.change_theme(theme_selector.get()),
        )
        language = ttk.Combobox(
            header, state="readonly", values=["English", "Português (BR)"], width=15
        )
        language.set("English" if self.language == "en" else "Português (BR)")
        language.pack(side="right", padx=(12, 0))
        language.bind(
            "<<ComboboxSelected>>", lambda event: self.change_language(language.get())
        )
        title = self.label(content, tr("subtitle", self.language), 20, wraplength=650)
        title.pack(fill="x", pady=(8, 0))
        title.bind(
            "<Configure>",
            lambda event: title.configure(wraplength=max(200, event.width)),
        )
        self.label(
            content, tr("ready", self.language), 10, self.MUTED, wraplength=650
        ).pack(fill="x", pady=(8, 20))
        for mode in ("manager", "system"):
            line = tk.Frame(
                content,
                bg=self.WHITE,
                padx=14,
                pady=8,
                highlightbackground="#5b4b28",
                highlightthickness=1,
            )
            line.pack(fill="x", pady=(0, 8))
            ttk.Radiobutton(
                line,
                text=tr(mode, self.language),
                variable=self.values["mode"],
                value=mode,
                command=self.mode_changed,
            ).pack(anchor="w")
            self.label(
                line, tr(mode + "_help", self.language), 10, self.MUTED, wraplength=610
            ).pack(anchor="w", padx=22, pady=(4, 0))
        form = tk.Frame(content, bg=self.BG)
        form.pack(fill="x", pady=(12, 4))
        form.columnconfigure(0, weight=1)
        form.columnconfigure(1, weight=1)
        fields = [
            "disk",
            "hostname",
            "username",
            "timezone",
            "locale",
            "keyboard",
            "desktop",
        ]
        for index, field in enumerate(fields):
            cell = tk.Frame(form, bg=self.BG)
            cell.grid(
                row=index // 2,
                column=index % 2,
                sticky="ew",
                padx=(0, 12),
                pady=(0, 10),
            )
            self.label(cell, tr(field, self.language), 10).pack(anchor="w", pady=(0, 4))
            if field in {"desktop", "disk"}:
                values = (
                    [
                        "gnome",
                        "xfce",
                        "minimal",
                        "kde",
                        "sway",
                        "xmonad-xlibre",
                        "river-xmonad",
                    ]
                    if field == "desktop"
                    else []
                )
                widget = ttk.Combobox(
                    cell,
                    textvariable=self.values[field],
                    values=values,
                    state="readonly",
                )
                if field == "disk":
                    self.disk_box = widget
            else:
                widget = ttk.Entry(cell, textvariable=self.values[field])
            widget.pack(fill="x")
            self.system_fields.append(widget)
        terminals_frame = tk.Frame(content, bg=self.BG)
        terminals_frame.pack(fill="x", pady=(6, 0))
        self.label(terminals_frame, tr("terminals", self.language), 13, self.GOLD).pack(
            anchor="w", pady=(0, 4)
        )
        terminal_line = tk.Frame(terminals_frame, bg=self.WHITE, padx=10, pady=5)
        terminal_line.pack(fill="x", pady=(0, 5))
        for name in core.TERMINAL_CHOICES:
            checkbox = ttk.Checkbutton(
                terminal_line,
                text=name,
                variable=self.terminal_vars[name],
                command=lambda: (
                    self.sync_terminal_defaults(),
                    self.invalidate(),
                ),
            )
            checkbox.pack(side="left", padx=(0, 12))
            self.system_fields.append(checkbox)
        default_terminal_line = tk.Frame(terminals_frame, bg=self.BG)
        default_terminal_line.pack(fill="x", pady=(0, 8))
        self.label(
            default_terminal_line, tr("default_terminal", self.language), 10
        ).pack(anchor="w", pady=(0, 4))
        self.default_terminal_box = ttk.Combobox(
            default_terminal_line,
            textvariable=self.values["default_terminal"],
            state="readonly",
            width=24,
        )
        self.default_terminal_box.pack(fill="x")
        self.system_fields.append(self.default_terminal_box)
        self.sync_terminal_defaults()
        browsers_frame = tk.Frame(content, bg=self.BG)
        browsers_frame.pack(fill="x", pady=(6, 0))
        self.label(browsers_frame, tr("browsers", self.language), 13, self.GOLD).pack(
            anchor="w", pady=(0, 4)
        )
        self.label(
            browsers_frame,
            tr("browsers_help", self.language),
            9,
            self.MUTED,
            wraplength=650,
        ).pack(anchor="w", pady=(0, 6))
        browser_line = tk.Frame(browsers_frame, bg=self.WHITE, padx=10, pady=5)
        browser_line.pack(fill="x", pady=(0, 5))
        for name in core.BROWSER_CHOICES:
            checkbox = ttk.Checkbutton(
                browser_line,
                text=name,
                variable=self.browser_vars[name],
                command=lambda: (
                    self.sync_browser_defaults(),
                    self.invalidate(),
                ),
            )
            checkbox.pack(side="left", padx=(0, 12))
            self.system_fields.append(checkbox)
        default_browser_line = tk.Frame(browsers_frame, bg=self.BG)
        default_browser_line.pack(fill="x", pady=(0, 8))
        self.label(default_browser_line, tr("default_browser", self.language), 10).pack(
            anchor="w", pady=(0, 4)
        )
        self.default_browser_box = ttk.Combobox(
            default_browser_line,
            textvariable=self.values["default_browser"],
            state="readonly",
            width=24,
        )
        self.default_browser_box.pack(fill="x")
        self.system_fields.append(self.default_browser_box)
        self.sync_browser_defaults()
        kernel_frame = tk.Frame(content, bg=self.BG)
        kernel_frame.pack(fill="x", pady=(6, 0))
        self.label(kernel_frame, tr("kernel", self.language), 13, self.GOLD).pack(
            anchor="w", pady=(0, 6)
        )
        kernel_form = tk.Frame(kernel_frame, bg=self.BG)
        kernel_form.pack(fill="x")
        kernel_form.columnconfigure(0, weight=1)
        kernel_form.columnconfigure(1, weight=1)
        kernel_labels = {
            tr("kernel_linux_libre", self.language): "linux-libre",
            tr("kernel_linux", self.language): "linux",
            tr("kernel_securityops", self.language): "securityops",
        }
        self.kernel_labels = kernel_labels
        self.values["kernel_display"] = tk.StringVar(
            value=next(
                label
                for label, value in kernel_labels.items()
                if value == self.values["kernel"].get()
            )
        )
        for index, (key, values) in enumerate(
            [
                ("kernel_display", list(kernel_labels)),
                ("kernel_version", []),
                ("kernel_config", []),
            ]
        ):
            cell = tk.Frame(kernel_form, bg=self.BG)
            cell.grid(
                row=index // 2, column=index % 2, sticky="ew", padx=(0, 12), pady=(0, 8)
            )
            label_key = "kernel" if key == "kernel_display" else key
            self.label(cell, tr(label_key, self.language), 10).pack(
                anchor="w", pady=(0, 4)
            )
            if key == "kernel_display":
                widget = ttk.Combobox(
                    cell,
                    textvariable=self.values["kernel_display"],
                    values=values,
                    state="readonly",
                )
                widget.bind(
                    "<<ComboboxSelected>>",
                    lambda event: self.kernel_selected(),
                )
            else:
                widget = ttk.Entry(cell, textvariable=self.values[key])
            widget.pack(fill="x")
            self.system_fields.append(widget)
        channels_frame = tk.Frame(content, bg=self.BG)
        channels_frame.pack(fill="x", pady=(6, 0))
        self.label(channels_frame, tr("channels", self.language), 13, self.GOLD).pack(
            anchor="w", pady=(0, 4)
        )
        self.label(
            channels_frame,
            tr("channels_help", self.language),
            9,
            self.MUTED,
            wraplength=650,
        ).pack(anchor="w", pady=(0, 6))
        for name in core.channels_catalog.OPTIONAL_NAMES:
            channel = core.channels_catalog.CHANNELS[name]
            line = tk.Frame(channels_frame, bg=self.WHITE, padx=10, pady=5)
            line.pack(fill="x", pady=(0, 5))
            checkbox = ttk.Checkbutton(
                line,
                text=name,
                variable=self.channel_vars[name],
                command=self.invalidate,
            )
            checkbox.pack(side="left")
            self.label(
                line,
                channel.description[self.language == "pt-BR"],
                9,
                self.MUTED,
                wraplength=580,
            ).pack(side="left", padx=(10, 0))
            self.system_fields.append(checkbox)
        tools = tk.Frame(content, bg=self.BG)
        tools.pack(fill="x", pady=(0, 12))
        ttk.Button(
            tools, text=tr("refresh", self.language), command=self.refresh_disks
        ).pack(side="left")
        ttk.Button(tools, text=tr("check", self.language), command=self.check).pack(
            side="left", padx=8
        )
        self.preview = tk.Text(
            content,
            height=8,
            bg=self.WHITE,
            fg=self.INK,
            relief="flat",
            padx=12,
            pady=12,
            wrap="word",
            font=("DejaVu Sans Mono", -13),
            takefocus=True,
        )
        self.preview.pack(fill="x")
        self.preview.insert("1.0", tr("terminal_note", self.language))
        self.preview.configure(state="disabled")
        actions = tk.Frame(content, bg=self.BG)
        actions.pack(fill="x", pady=(12, 0))
        ttk.Button(actions, text=tr("review", self.language), command=self.review).pack(
            side="left"
        )
        self.install_button = ttk.Button(
            actions,
            text=tr("launch", self.language),
            style="Accent.TButton",
            command=self.start,
            state="disabled",
        )
        self.install_button.pack(side="right")
        self.mode_changed()

    def options(self):
        values = self.values
        return core.Options(
            mode=str(values["mode"].get()),
            disk=str(values["disk"].get()),
            hostname=str(values["hostname"].get()),
            username=str(values["username"].get()),
            timezone=str(values["timezone"].get()),
            locale=str(values["locale"].get()),
            keyboard=str(values["keyboard"].get()),
            desktop=str(values["desktop"].get()),
            kernel=str(values["kernel"].get()),
            kernel_version=str(values["kernel_version"].get()).strip(),
            kernel_config=str(values["kernel_config"].get()).strip(),
            terminals=tuple(
                name for name, variable in self.terminal_vars.items() if variable.get()
            ),
            default_terminal=str(values["default_terminal"].get()),
            browsers=tuple(
                name for name, variable in self.browser_vars.items() if variable.get()
            ),
            default_browser=str(values["default_browser"].get()),
            channels=tuple(
                name for name, variable in self.channel_vars.items() if variable.get()
            ),
        )

    def sync_terminal_defaults(self):
        selected = [
            name for name in core.TERMINAL_CHOICES if self.terminal_vars[name].get()
        ]
        self.default_terminal_box.configure(values=selected)
        current = self.values["default_terminal"].get()
        if current not in selected:
            self.values["default_terminal"].set(selected[0] if selected else "")

    def sync_browser_defaults(self):
        selected = [
            name for name in core.BROWSER_CHOICES if self.browser_vars[name].get()
        ]
        self.default_browser_box.configure(values=selected)
        current = self.values["default_browser"].get()
        if current not in selected:
            self.values["default_browser"].set(selected[0] if selected else "")

    def kernel_selected(self):
        display = str(self.values["kernel_display"].get())
        self.values["kernel"].set(str(self.kernel_labels.get(display, "linux-libre")))
        self.mode_changed()

    def invalidate(self, *unused):
        self.generation += 1
        self.reviewed = False
        button = getattr(self, "install_button", None)
        if button is not None and button.winfo_exists():
            button.configure(state="disabled")

    def mode_changed(self):
        enabled = self.values["mode"].get() == "system"
        for widget in self.system_fields:
            if isinstance(widget, self.ttk.Combobox):
                widget.configure(state="readonly" if enabled else "disabled")
            else:
                widget.configure(state="normal" if enabled else "disabled")
        kernel = self.values["kernel"].get()
        if enabled:
            nonguix_required = kernel in {"linux", "securityops"}
            self.channel_vars["nonguix"].set(
                self.channel_vars["nonguix"].get() or nonguix_required
            )
        self.invalidate()

    def change_language(self, value):
        self.language = "en" if value == "English" else "pt-BR"
        self.build()

    def display(self, text):
        self.preview.configure(state="normal")
        self.preview.delete("1.0", "end")
        self.preview.insert("1.0", text)
        self.preview.configure(state="disabled")

    def error(self, exc):
        from tkinter import messagebox

        messagebox.showerror(tr("error", self.language), str(exc), parent=self.root)

    def background_query(self, work, apply):
        if self.query_running:
            return
        self.query_running = True
        self.invalidate()
        self.display(tr("query_running", self.language))
        generation = self.generation

        def worker():
            try:
                result, error = work(), None
            except Exception as exc:  # noqa: BLE001 - deliver worker failures to Tk rather than lose completion
                result, error = None, exc
            self.query_results.put((generation, result, error, apply))

        threading.Thread(target=worker, daemon=True).start()
        self.root.after(25, self.poll_query)

    def poll_query(self):
        try:
            generation, result, error, apply = self.query_results.get_nowait()
        except queue.Empty:
            self.root.after(25, self.poll_query)
            return
        self.query_running = False
        if generation != self.generation:
            return
        if error:
            self.error(error)
        else:
            try:
                apply(result)
            except (KeyError, TypeError, ValueError) as exc:
                self.error(exc)

    def refresh_disks(self):
        def show(entries):
            disks = [node for node in entries if node["type"] == "disk"]
            self.disk_box.configure(values=[node["name"] for node in disks])
            self.display(
                "\n".join(
                    f"{node['name']}  ·  {int(node['size']) / 1024**3:.1f} GiB  ·  ro={node['ro']}"
                    for node in disks
                )
                or tr("no_disks", self.language)
            )

        self.background_query(core.inventory, show)

    def check(self):
        mode = self.values["mode"].get()
        self.background_query(
            lambda: core.doctor(mode),
            lambda findings: self.display(
                "\n".join(
                    f"{'OK' if ok else 'MISSING'}  {name}" for name, ok in findings
                )
            ),
        )

    def review(self):
        if self.query_running:
            self.invalidate()
        try:
            options = self.options()
            plan = translated_plan(options, self.language, core.make_plan(options))
            self.display(tr("plan", self.language) + "\n\n" + "\n".join(plan))
            self.reviewed = True
            self.install_button.configure(state="normal")
        except (core.InstallError, OSError, ValueError) as exc:
            self.error(exc)

    def start(self):
        if not self.reviewed:
            return
        try:
            self.child = subprocess.Popen(
                terminal_command(self.options(), self.language, self.theme),
                cwd=core.ROOT,
            )
            self.invalidate()
            self.display(tr("terminal_note", self.language))
        except (core.InstallError, OSError) as exc:
            self.error(exc)


def launch(options, language, theme="dark"):
    if os.geteuid() == 0:
        raise core.InstallError(
            "Run the GUI as your ordinary user; sudo is requested in the terminal."
        )
    try:
        import tkinter as tk

        root = tk.Tk()
    except ImportError as exc:
        raise core.InstallError(
            "Install Python Tk (python3-tk / python3-tkinter), or use ./installer.sh wizard."
        ) from exc
    except Exception as exc:
        raise core.InstallError(
            "No graphical display is available. Use ./installer.sh wizard."
        ) from exc
    InstallerWindow(root, options, language, theme)
    root.mainloop()
