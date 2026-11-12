"""Small explicit English / Portuguese interface catalogue."""

TEXT = {
    "interrupted": (
        "Interrupted. The target may already be modified; inspect the log and disks before retrying.",
        "Interrompido. O destino pode já ter sido alterado; revise o log e os discos antes de tentar novamente.",
    ),
    "dark": ("Dark · default", "Escuro · padrão"),
    "light": ("Light", "Claro"),
    "subtitle": (
        "A clearer path to GNU Guix.",
        "Um caminho mais simples para o GNU Guix.",
    ),
    "plan": (
        "PLAN ONLY · no installation commands executed",
        "SOMENTE PLANO · nenhum comando de instalação executado",
    ),
    "manager": ("Guix package manager", "Gerenciador de pacotes Guix"),
    "system": ("Guix System", "Guix System"),
    "manager_help": (
        "Keep your distribution. Add reproducible packages.",
        "Mantenha sua distribuição. Adicione pacotes reproduzíveis.",
    ),
    "system_help": (
        "Install a complete OS onto a separate disk. Erases that disk.",
        "Instale um sistema completo em outro disco. Apaga esse disco.",
    ),
    "review": ("Review installation", "Revisar instalação"),
    "launch": ("Continue in terminal", "Continuar no terminal"),
    "choose": ("Installation type", "Tipo de instalação"),
    "settings": ("Your system", "Seu sistema"),
    "disk": ("Target disk", "Disco de destino"),
    "hostname": ("Computer name", "Nome do computador"),
    "username": ("Administrator", "Administrador"),
    "timezone": ("Timezone", "Fuso horário"),
    "locale": ("Locale", "Idioma do sistema"),
    "keyboard": ("Keyboard layout", "Layout do teclado"),
    "desktop": ("Desktop", "Ambiente gráfico"),
    "firmware": (
        "Enable Nonguix Linux + proprietary firmware",
        "Ativar Linux + firmware proprietário do Nonguix",
    ),
    "firmware_help": (
        "Optional. Changes the free-software policy. Uses authenticated pinned channels.",
        "Opcional. Altera a política de software livre. Usa canais autenticados e fixados.",
    ),
    "refresh": ("Refresh disks", "Atualizar discos"),
    "check": ("Check prerequisites", "Verificar requisitos"),
    "ready": (
        "Plan first. Confirm every system change in the terminal.",
        "Revise o plano. Confirme as alterações no terminal.",
    ),
    "safety": ("YOUR DISKS, YOUR DECISION", "SEUS DISCOS, SUA DECISÃO"),
    "safety_body": (
        "Busy disks are refused. A disk erase always requires its exact name. No automatic reboot.",
        "Discos em uso são recusados. Apagar um disco exige seu nome exato. Sem reinício automático.",
    ),
    "terminal_note": (
        "A terminal opens for sudo, private password entry and live progress. Closing this window does not stop that terminal.",
        "Um terminal será aberto para sudo, senha privada e progresso. Fechar esta janela não encerra esse terminal.",
    ),
    "missing_terminal": (
        "No supported terminal found. Run ./installer.sh wizard from a terminal.",
        "Nenhum terminal compatível encontrado. Execute ./installer.sh wizard em um terminal.",
    ),
    "error": ("Installation stopped", "Instalação interrompida"),
    "confirm": (
        "Type the exact phrase to erase the target",
        "Digite a frase exata para apagar o destino",
    ),
    "password": (
        "Administrator password (12+ characters): ",
        "Senha do administrador (12+ caracteres): ",
    ),
    "repeat": ("Repeat password: ", "Repita a senha: "),
    "password_error": (
        "Passwords must match, contain 12+ characters and no control characters.",
        "As senhas devem ser iguais, ter 12+ caracteres e nenhum caractere de controle.",
    ),
    "continue": ("Type INSTALL to continue: ", "Digite INSTALL para continuar: "),
    "cancelled": (
        "Cancelled. No installation started.",
        "Cancelado. Nenhuma instalação iniciada.",
    ),
    "done": (
        "Installation finished. Review the output; then reboot or log in again when ready.",
        "Instalação concluída. Revise a saída; depois reinicie ou faça login novamente quando quiser.",
    ),
    "manager_plan": (
        "Install GNU Guix alongside the current distribution.\nVerify the pinned official installer, then request sudo.\nThe official installer verifies archive signatures and configures the daemon.\nNo partitioning; open a new login shell afterward.",
        "Instalar o GNU Guix junto à distribuição atual.\nVerificar o instalador oficial fixado e solicitar sudo.\nO instalador oficial verifica assinaturas e configura o daemon.\nSem particionamento; abra uma nova sessão ao terminar.",
    ),
}


def tr(key, language="en"):
    return TEXT[key][language == "pt-BR"]


def translated_plan(options, language, english):
    if language != "pt-BR":
        return english
    if options.mode == "manager":
        return tr("manager_plan", language).splitlines()
    return [
        f"APAGAR TODOS OS DADOS: {options.disk} (mínimo 32 GiB).",
        "Exigir x86_64 UEFI e Secure Boot desativado; recusar discos em uso/protegidos.",
        "Criar GPT: ESP FAT32 de 1 GiB + raiz ext4 no restante (sem criptografia).",
        f"Computador {options.hostname}; administrador {options.username}; ambiente {options.desktop}.",
        f"Idioma {options.locale}; fuso {options.timezone}; teclado {options.keyboard}.",
        "Kernel: "
        + (
            "Linux + firmware proprietário (Nonguix opcional)."
            if options.nonguix
            else "Linux-libre."
        ),
        "Usar canais autenticados e fixados por commit com guix system init.",
        "Manter root bloqueado; solicitar senha do administrador em modo privado.",
        f"Confirmação obrigatória: ERASE {options.disk}",
        "Sem reinício automático. Gravações interrompidas não podem ser desfeitas.",
    ]
