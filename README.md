# SISMD_Erlang

An **Erlang/OTP** implementation of Single Instruction, Multiple Data (SISMD) parallelism, demonstrating lightweight process-based data processing.

---

## 📚 Overview

## 🌐 System Overview

This project implements a distributed sensor network, where each sensor runs on its own Erlang virtual machine and simulates periodic data collection (e.g., temperature, humidity). These sensors communicate asynchronously with a central server, which aggregates data for analysis. If a sensor cannot directly reach the server, it relays messages through neighboring sensors.

Key system characteristics:

- **Autonomous Sensors**: Each sensor operates independently and transmits data periodically.
- **Asynchronous Messaging**: Communication is non-blocking and based on message-passing between processes.
- **Data Aggregation**: A central server collects and stores data from all sensors.
- **Fault Tolerance**: The system detects sensor or relay failures, automatically reroutes data through alternative paths, and simulates recoveries.
- **Dynamic Reconfiguration**: Upon failure detection, the system adapts by re-routing and maintaining continuous operation.
- **Scalability**: New sensors can be added without reconfiguring the entire system, enabling easy horizontal scaling.

This simulation also reflects real-world deployable systems and demonstrates Erlang’s capabilities in concurrency, resilience, and distributed fault recovery.


This project explores parallel data processing using Erlang. It divides input data and processes each part concurrently using separate Erlang processes, following the SISMD model.

---

## ⚙️ Features

- Parallel execution of the same function over multiple data partitions  
- Worker process monitoring and result aggregation  
- Basic fault tolerance using OTP supervisors  
- Example operations: `map`, `filter`, and `reduce`

---

## 📦 Requirements

- **Erlang/OTP 28.0** or later  

---

## ▶️ Execution Instructions

### 🖥️ Server

Start the server and monitor in a terminal:

```bash
erl -sname server1 -setcookie mycookiee
```

Compile and start the server:

```erlang
c(server).
c(monitor).
ServerPid = server:start().
```

To simulate a server failure:

```erlang
server:stop(ServerPid).
```

To recover the server:

```erlang
ServerPid = server:start().
```

---

### 📡 Clients (Sensors)

Each client must run in a separate terminal. Replace `N` with the client ID and `[Neighbors]` with the list of neighbor sensor IDs.

**Client 1:**

```bash
erl -sname client1 -setcookie mycookiee
```

```erlang
client:start(1, 5000, [0,2,3], 'server1@localhost', 'monitor@localhost').
```

**Client 2:**

```bash
erl -sname client2 -setcookie mycookiee
```

```erlang
client:start(2, 5000, [1,3], 'server1@localhost', 'monitor@localhost').
```

**Client 3:**

```bash
erl -sname client3 -setcookie mycookiee
```

```erlang
client:start(3, 5000, [0,1,2], 'server1@localhost', 'monitor@localhost').
```

---

### ⚠️ Simulate Sensor Failures

To simulate a failure in sensor 2:

```erlang
client:simulate_failure(2).
```

To simulate recovery of sensor 2:

```erlang
client:simulate_recovery(2).
```

---

## 📁 Project Structure

```
.
├── src/
│   ├── client.erl        
│   ├── monitor.erl
│   └── server.erl
```

---

## 📄 License

MIT License — feel free to use, modify, and distribute.

---
