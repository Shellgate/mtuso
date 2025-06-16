# MTUSO (MTU/MSS Smart Optimizer)

> **Author:** [Shellgate](https://github.com/Shellgate)

A modern, automated, and user-friendly Linux CLI tool for smart and live optimization of MTU and MSS on your network interfaces and VPN tunnels.  
It continuously finds the best values for your network by testing and tuning in real-time — with full support for jumbo frames and interactive, colored menus.

---

## 🚀 Quick Install

Copy and paste this command in your terminal **(Debian/Ubuntu & derivatives):**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Shellgate/mtuso/main/mtuso.sh)
```

---

## 🛠 Features

- **Auto-detects and sets the best MTU/MSS** based on latency, packet loss, and throughput
- **Works with all interfaces and VPN tunnels**
- **Jumbo frame support** (MTU up to 9000)
- **Live and interactive menu:** Start, pause, resume, disable, uninstall, reset
- **Beautiful CLI UI with colors and status display**
- **Auto-install script and systemd integration:** Runs as a service if enabled
- **No manual config needed** – just run and enjoy optimal network performance!

---

## 🎬 Usage

After installation, simply run:

```bash
mtuso
```

You’ll see the interactive menu:

![mtuso-demo](assets/mtuso-demo.png)

> *(Add your screenshot or GIF in `assets/mtuso-demo.png`)*

---

## ⚡️ Uninstall

You can safely uninstall everything via the menu, or simply:

```bash
mtuso.sh --uninstall
```

---

## 👨‍💻 Author

- [Shellgate on GitHub](https://github.com/Shellgate)

---

## 📄 License

MIT
