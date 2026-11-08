# 提案：验收测试用了不是前置节点的文件，orc 冻结前没查出来

状态：**林翰 2026-11-08 选 C**（「P1 开始」会话的分析，林翰转来），已实现：`test_dependency_problems`，验证会话的产出校验里多一项。`fintelli-p1-1-2` 执行阶段发现。

## 发生了什么

`fintelli-p1-1-2` 的 DAG 里，`intake-fakes`（新建 `harness_core/intake/fake.py`）和 `intake-service` 都只依赖 `intake-context-runner`，两个节点并行开工，起点是同一个提交。

验证会话写的 `test_intake_service_accept.py` 里有 `from harness_core.intake import fake`，拿 `fake.done`、`fake.cannot` 当处理器。`intake-service` 的工作区里没有 `fake.py`，它的检查 `intake-service-all` 在提交关口一定失败，`service.py` 写对了也没用。执行会话停下来提问，节点卡住。

- 验证会话的说明里本来就有这条规则（「挂在节点 X 上的检查，只能依赖 X 和它前置节点的改动」），但 orc 不检查，STATE.md 写着「orc 不自动判断」。
- 第一次跑（`fintelli-p1-1`）的测试没用 `fake.py`，没出事。测试每轮重新写，这次写法不同就出事了。所以靠运气不行。

## 三条路

- A：再放弃、再重跑。测试仍是重新写，不保证不再犯。
- B：节点重新过关口前，先把工作区同步到集成分支的最新提交。这次能过，只是碰巧 `intake-fakes` 先集成了；换个先后顺序照样出问题。「P1 开始」会话自己收回了这条。
- **C（选这条）**：在 orc 校验验证会话产出时加一项确定性检查。每个检查跑到的测试，只能导入它所在节点和前置节点新建的文件；用到别的就退回验证会话重写，不让冻结。

## 怎么查（C）

- **检查跑哪些测试**：检查命令里写了的 `.py` 测试文件（去掉 `::测试名`）；写了目录的，就是目录下的全部测试文件。
- **跟着走**：测试文件导入的其他测试文件（辅助模块），以及测试文件上层目录里的 `conftest.py`（pytest 会自动加载）。
- **读出导入**：用 Python 的 `ast` 读每条 `import` / `from … import …`，文件开头和函数里面的都算（brief 要求把被测接口放在函数里导入）。相对导入按测试文件所在的包算。绝对导入的根是仓库根、`src/` 和测试文件所在目录。
- **算不算问题**：用到的文件在起点上不存在，并且是由某个节点新建的；这个节点既不是检查所在的节点，也不是它的前置节点（`depends_on` 层层往上）。仓库里已有的代码都可以用。
- **退回**：和其他校验问题一样，发回验证会话（同一个会话，自动修 2 次，再不行就 `mediate`）。消息写明是哪些检查、哪个测试、哪一行导入、用到哪个节点的哪个文件，以及这个节点的前置节点是哪些。

## 不查的（写进 STATE.md）

- 字符串形式、运行时才导入的写法，比如 `resolve_processor("harness_core.intake.fake:cannot")`，这里不查。原因是 `intake-context-runner` 的验收标准本身就要求 `DEFAULT_PROCESSOR == "harness_core.intake.fake:hold"`，这只是比较字符串，不需要 `fake.py` 存在。把字符串也当成导入，会误退这个正确的测试。
- 已有文件被别的节点改过之后的新行为，这里也不查，只靠 brief。
- 非 Python 的测试文件不查。

## 实测

- 在 `fintelli-p1-1-2` 冻结的真实测试和 DAG 上跑：只报 `intake-service-processor-args`、`intake-service-all` 两个检查，都指向 `test_intake_service_accept.py` 的 `from harness_core.intake import fake`。`intake-context-runner` 只比较 `"…fake:hold"` 字符串的测试没被误报；`intake-app` 用 `fake` 也没被报，因为 `intake-fakes` 是它的前置节点。
- 在第一次跑（`fintelli-p1-1`）冻结的 10 个测试文件上：0 个问题。那一轮的测试实际也都过了。

## 对正在跑的 P1-1

`fintelli-p1-1-2` 的计划和测试已经冻结、签了名，改不了。合并后由「P1 开始」会话 `orc abandon` 这一轮，再用 `orc phase` 重跑。新一轮的测试如果再越过依赖，会在审阅页之前就被退回重写。
