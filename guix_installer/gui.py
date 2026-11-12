"""Unprivileged native desktop form. All installation policy lives in core."""

import os
import shutil
import subprocess
import sys
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
        self.values = {
            key: (
                tk.BooleanVar(value=value)
                if isinstance(value, bool)
                else tk.StringVar(value=value)
            )
            for key, value in asdict(options).items()
        }
        self.reviewed = False
        self.child = None
        self.system_fields = []
        root.title("GNU Guix Installer")
        root.geometry("1020x820")
        root.minsize(780, 640)
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
        side = tk.Frame(root, bg=self.SIDEBAR, width=230)
        side.pack(side="left", fill="y")
        side.pack_propagate(False)
        self.label(side, "GNU\nGUIX", 30, self.ORANGE).pack(
            anchor="w", padx=28, pady=(36, 8)
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
                values = ["gnome", "xfce", "minimal"] if field == "desktop" else []
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
        firmware = ttk.Checkbutton(
            form, text=tr("firmware", self.language), variable=self.values["nonguix"]
        )
        firmware.grid(row=4, column=0, columnspan=2, sticky="w")
        self.system_fields.append(firmware)
        self.label(
            form, tr("firmware_help", self.language), 9, self.MUTED, wraplength=620
        ).grid(row=5, column=0, columnspan=2, sticky="w", pady=(4, 8))
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
            nonguix=bool(values["nonguix"].get()),
        )

    def invalidate(self, *unused):
        self.reviewed = False
        self.install_button.configure(state="disabled")

    def mode_changed(self):
        enabled = self.values["mode"].get() == "system"
        for widget in self.system_fields:
            widget.configure(
                state=(
                    "readonly" if isinstance(widget, self.ttk.Combobox) else "normal"
                )
                if enabled
                else "disabled"
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

    def refresh_disks(self):
        try:
            disks = [node for node in core.inventory() if node["type"] == "disk"]
            self.disk_box.configure(values=[node["name"] for node in disks])
            self.display(
                "\n".join(
                    f"{node['name']}  ·  {int(node['size']) / 1024**3:.1f} GiB  ·  ro={node['ro']}"
                    for node in disks
                )
                or "No disks / Nenhum disco"
            )
        except (core.InstallError, OSError, ValueError) as exc:
            self.error(exc)

    def check(self):
        try:
            self.display(
                "\n".join(
                    f"{'OK' if ok else 'MISSING'}  {name}"
                    for name, ok in core.doctor(self.values["mode"].get())
                )
            )
        except (core.InstallError, OSError) as exc:
            self.error(exc)

    def review(self):
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
