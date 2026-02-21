# AutoSage 🧙‍♂️⚙️

**AutoSage** is a high-performance, multi-physics simulation server designed specifically for **LLM Agent workflows**. It transforms complex engineering tasks—ranging from structural analysis (FEA) to fluid dynamics (CFD) and circuit simulation—into a standardized API that autonomous agents can navigate natively.

## 🌟 The Core Philosophy
Traditional simulation software requires a human-in-the-loop to click buttons and manage mesh files. **AutoSage** runs as a standalone server with an **OpenAI-compatible interface**, allowing agents like **OpenHands**, **Plandex**, or custom GPT-based orchestrators to:
1.  **Generate** geometry through code.
2.  **Execute** multi-physics simulations via tool-calling.
3.  **Analyze** results using real-time SSE (Server-Sent Events) feedback.

---

## 🛠 Key Features
* **Agent-First Architecture:** Exposes tools via a standard OpenAI-style JSON schema for seamless integration with existing agent frameworks.
* **Multi-Physics Solver Suite:** High-fidelity native FFI bridges to:
    * **MFEM:** High-order finite element analysis.
    * **Open3D:** Point cloud and 3D geometry processing.
    * **VTK:** Professional-grade scientific visualization and rendering.
    * **ngspice:** Industry-standard analog circuit simulation.
* **Cross-Platform Performance:** Native Swift implementation optimized for **macOS (Apple Silicon)** and **Linux (Headless/Docker)**.
* **Real-time Orchestration:** Streaming logs and state updates allow agents to "see" the simulation progress and correct errors mid-workflow.

---

## 🚀 Getting Started

### 1. Prerequisites
Ensure you have the required native libraries installed. We provide a universal setup script for both macOS and Linux:
```bash
chmod +x setup.sh
./setup.sh
```

### 2. Build & Run
Compile the backend server:
```bash
swift build -c release
swift run AutoSageServer --port 8080
```

### 3. Connect Your Agent
Point your agent framework to the AutoSage endpoint:
* **Base URL:** `http://localhost:8080/v1`
* **API Key:** `local-development` (or as configured)

---
## 🏗 Supported Agent Frameworks
AutoSage acts as the "engineering brains" for high-autonomy agents. It is specifically optimized for:

* **Open Claw:** Leverage AutoSage's multi-physics tools for deep-reasoning engineering tasks, allowing the agent to verify designs through real-world physics simulation before finalizing engineering designs.
* **OpenHands (formerly OpenDevin):** For autonomous software/hardware co-design and iterative prototyping.
* **Plandex:** For long-running, multi-step engineering project planning that requires validated simulation checkpoints.
* **Custom Agents:** Any framework using LangChain, Semantic Kernel, or raw OpenAI SDKs.

---

## 📜 License
MIT
