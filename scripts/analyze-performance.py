#!/usr/bin/env python3
"""Summarize the allowlisted numeric windows in QuietDesk diagnostic exports."""

import argparse
from dataclasses import dataclass, field
from datetime import datetime
from decimal import Decimal
import json
from pathlib import Path
import re
import sys


METRIC_UNITS = {
    **dict.fromkeys(("sendQueue", "sendCompletion", "receiveHeaderWait", "receiveBody", "messageHandler", "roundTrip",
                     "tcpSmoothedRTT", "tcpMinimumRTT", "tcpRTTVariance", "tcpReportDuration",
                     "captureAge", "encode", "encodeCallbackQueue", "videoAck", "decodeQueue",
                     "decodePrepare", "decode", "decodeToDisplay", "displayEnqueue", "mediaRoundTrip",
                     "mediaReassembly", "mediaSwitch", "mediaDecodeInterval"), "microseconds"),
    **dict.fromkeys(("encodedBytes", "keyframeBytes", "pendingSendBytes", "tcpRetransmittedBytes", "tcpOutOfOrderBytes",
                     "tcpSentBytes", "tcpReceivedBytes", "mediaDatagramSentBytes", "mediaDatagramReceivedBytes",
                     "mediaRepairBytes"), "bytes"),
    **dict.fromkeys(("captureReplaced", "displayReplaced", "encoderHardware", "decoderHardware",
                     "videoOutstanding", "mediaExpired", "mediaRecovery", "mediaTransport"), "count"),
}
MESSAGE_KINDS = dict(enumerate((
    "hello", "video", "acknowledgement", "input", "ping", "pong", "clipboard", "requestClipboard",
    "releaseInput", "inputStatus", "clipboardSettings", "clipboardBegin", "clipboardEntry", "clipboardChunk",
    "clipboardEnd", "clipboardReceipt", "clipboardCancel", "streamSettingsRequest", "streamSettingsResult",
    "controlStatus", "deviceIdentity", "sessionEffectsRequest", "sessionEffectsResult", "sessionPauseRequest",
    "sessionPauseResult", "mediaControl", "mediaFrame", "mediaFeedback", "cursorControl", "cursorShape", "cursorPosition"), start=1))
OTHER_EVENTS = set((
    "applicationStarted applicationStopped connectionStarted connectionReady connectionClosed connectionFailed "
    "connectionMetrics reconnectScheduled inputFailed hostStarted hostStopped captureStarted captureStopped "
    "captureFailed streamConfigured displayChanged sessionPaused sessionResumed sessionEffectsChanged "
    "clipboardOffered clipboardOfferReceived clipboardAccepted clipboardRejected clipboardCompleted "
    "clipboardFailed clipboardEchoSuppressed permissionChanged exportRequested "
    "exportCompleted exportFailed counters performanceDiagnosticsChanged"
).split())
SUMMARY_FIELDS = {"metric", "messageKind", "unit", "count", "minimum", "maximum", "mean",
                  "p95UpperBound", "worstIdentifier", "windowMilliseconds"}
INTEGER_FIELDS = ("count", "minimum", "maximum", "mean", "p95UpperBound", "windowMilliseconds")
MAX_INTEGER = (1 << 63) - 1
MAX_LINE_BYTES = 1_048_576


def is_integer(value, maximum=MAX_INTEGER):
    return type(value) is int and 0 <= value <= maximum


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate JSON key")
        result[key] = value
    return result


def valid_window(record):
    if set(record) != {"timestamp", "event", "role", "performance", "connectionID"}:
        return False
    if record["role"] not in ("host", "viewer") or not is_integer(record["connectionID"]):
        return False
    timestamp = record["timestamp"]
    if not isinstance(timestamp, str) or not re.fullmatch(
            r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})", timestamp):
        return False
    try:
        datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
    except ValueError:
        return False
    summary = record["performance"]
    if not isinstance(summary, dict) or not set(summary).issubset(SUMMARY_FIELDS):
        return False
    metric, unit = summary.get("metric"), summary.get("unit")
    if not isinstance(metric, str) or metric not in METRIC_UNITS or unit != METRIC_UNITS[metric]:
        return False
    if not all(is_integer(summary.get(key)) for key in INTEGER_FIELDS) or summary["count"] == 0:
        return False
    if not summary["minimum"] <= summary["mean"] <= summary["maximum"]:
        return False
    if not summary["minimum"] <= summary["p95UpperBound"] <= summary["maximum"]:
        return False
    kind, identifier = summary.get("messageKind"), summary.get("worstIdentifier")
    return (kind is None or is_integer(kind, 255) and kind in MESSAGE_KINDS) and (
        identifier is None or is_integer(identifier, (1 << 64) - 1))


@dataclass
class Aggregate:
    count: int = 0
    weighted_total: int = 0
    minimum: int = MAX_INTEGER
    maximum: int = -1
    maximum_window_p95: int = 0
    windows: int = 0
    worst_identifier: object = None
    worst_line: int = 0

    def add(self, summary, line):
        self.count += summary["count"]
        self.weighted_total += summary["mean"] * summary["count"]
        self.minimum = min(self.minimum, summary["minimum"])
        if summary["maximum"] > self.maximum or (
                summary["maximum"] == self.maximum and self.worst_identifier is None
                and summary.get("worstIdentifier") is not None):
            self.maximum = summary["maximum"]
            self.worst_identifier = summary.get("worstIdentifier")
            self.worst_line = line
        self.maximum_window_p95 = max(self.maximum_window_p95, summary["p95UpperBound"])
        self.windows += 1

    @property
    def mean(self):
        return Decimal(self.weighted_total) / self.count


@dataclass
class FileReport:
    path: Path
    groups: dict = field(default_factory=dict)
    valid_windows: int = 0
    other_events: int = 0
    skipped_lines: int = 0


def read_report(path):
    report = FileReport(Path(path))
    run, line_number = 0, 0
    with report.path.open("rb") as source:
        while raw := source.readline(MAX_LINE_BYTES + 1):
            line_number += 1
            if len(raw) > MAX_LINE_BYTES:
                while raw and not raw.endswith(b"\n"):
                    raw = source.readline(MAX_LINE_BYTES + 1)
                report.skipped_lines += 1
                continue
            if not raw.strip():
                continue
            try:
                record = json.loads(raw, object_pairs_hook=unique_object)
            except (ValueError, UnicodeError, RecursionError):
                report.skipped_lines += 1
                continue
            if not isinstance(record, dict) or not isinstance(record.get("event"), str):
                report.skipped_lines += 1
                continue
            event = record["event"]
            if event in OTHER_EVENTS:
                report.other_events += 1
                if event == "applicationStarted":
                    run += 1
                continue
            if event != "performanceWindow" or not valid_window(record):
                report.skipped_lines += 1
                continue
            summary = record["performance"]
            key = (run, record["role"], record["connectionID"], summary["metric"], summary.get("messageKind"))
            report.groups.setdefault(key, Aggregate()).add(summary, line_number)
            report.valid_windows += 1
    return report


def measurement(value, unit):
    if unit == "microseconds":
        return f"{Decimal(value) / 1000:.3f} ms"
    if unit == "bytes":
        return f"{Decimal(value) / 1024:.3f} KiB"
    return f"{Decimal(value):.3f} count"


def render_report(reports):
    lines = ["# QuietDesk 性能诊断摘要", "",
             "各文件、角色、本地启动段、连接、指标和消息类型分别统计，不合并双端或不同连接。", "",
             "均值按各窗口样本数加权；原始窗口均值已取整，因此汇总均值是近似值。"
             "P95 列仅为**各窗口 P95 上界的最大值**，不是全会话 P95。", "",
             "耗时由 µs 转为 ms，字节由 B 转为 KiB（1024 B）；count 表示该指标的计数值。"
             "样本数是观测次数。零是已记录的值或计时精度内的结果，不代表整个流程无耗时。", "",
             "峰值序号只在对应本地连接内有效；视频/ACK 的序号可在确认属于同一会话后人工核对双端帧，"
             "ping/pong 序号属于心跳探测。缺失标识显示“未记录”。同值峰值保留一个对应标识。"
             "不同进程的 connectionID 相同不代表同一会话；不能跨端直接相减单调时钟。", ""]
    for index, report in enumerate(reports, start=1):
        name = "".join(char if char.isprintable() else "?" for char in report.path.name)
        name = name.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
        name = re.sub(r"([\\`*_{}\[\]()#+.!|])", r"\\\1", name)
        lines.extend([f"## 文件 {index}：{name}", "",
                      f"有效性能窗口：{report.valid_windows}；其他已知事件：{report.other_events}；"
                      f"跳过未知或损坏行：{report.skipped_lines}。", ""])
        if not report.groups:
            lines.extend(["**缺少诊断数据**：没有合法且包含样本的性能窗口，不能判定为零耗时。", ""])
            continue
        previous = None
        for key, aggregate in sorted(report.groups.items(), key=lambda pair: (*pair[0][:-1], pair[0][-1] if pair[0][-1] is not None else -1)):
            run, role, connection, metric, kind = key
            if (run, role, connection) != previous:
                run_label = str(run) if run else "起始片段（未见启动事件）"
                role_label = "控制端 viewer" if role == "viewer" else "共享端 host"
                lines.extend(["", f"### 本地启动段 {run_label} · {role_label} · 连接 {connection}", "",
                              "| 指标 | 消息类型 | 窗口数 | 样本数 | 最小值 | 加权均值 | 最大值 | 各窗口 P95 上界的最大值 | 峰值序号 / 源行 |",
                              "|---|---|---:|---:|---:|---:|---:|---:|---|"])
                previous = (run, role, connection)
            unit = METRIC_UNITS[metric]
            message = "未分类" if kind is None else f"{MESSAGE_KINDS[kind]} ({kind})"
            identifier = "未记录" if aggregate.worst_identifier is None else str(aggregate.worst_identifier)
            cells = [metric, message, str(aggregate.windows), str(aggregate.count),
                     measurement(aggregate.minimum, unit), measurement(aggregate.mean, unit),
                     measurement(aggregate.maximum, unit), measurement(aggregate.maximum_window_p95, unit),
                     f"{identifier} / 第 {aggregate.worst_line} 行"]
            lines.append("| " + " | ".join(cells) + " |")
        lines.append("")
    lines.extend(["## 解读边界", "",
                  "先比较 video 的 receiveBody、sendQueue、sendCompletion、pendingSendBytes 与 roundTrip；"
                  "再比较 encode、encodeCallbackQueue、decodePrepare、decode 和 decodeToDisplay。"
                  "数值提供排查方向，不会自动证明网络、编码器或界面是根因。", "",
                  "sendCompletion 只到 Network.framework contentProcessed，不等于网络交付；"
                  "displayEnqueue 测显示 sample 准备及入队，不等于实际上屏。receiveBody 不含等待帧头的空闲，"
                  "但包含消息体传输、对端生产和本端调度。receiveHeaderWait 包含静止等待和帧间隔，"
                  "不能直接当作网络时延。硬件状态缺少样本不等于软件编解码。", "",
                  "tcpSmoothedRTT、tcpMinimumRTT 和 tcpRTTVariance 来自系统 TCP 报告，区别于有序消息通道中的应用 roundTrip；"
                  "tcpRetransmittedBytes 和 tcpOutOfOrderBytes 是各次传输报告区间的字节计数，表中均值不是速率。"
                  "tcpSentBytes、tcpReceivedBytes 和 tcpReportDuration 保留相同报告的传输量与实际区间时长；"
                  "聚合窗口可能与报告区间错开，不能把窗口均值直接解释为吞吐。"
                  "这些指标每个报告各记一个样本，P95 也不是逐包分位数；缺少报告不能解释为零重传。", "",
                  "不同指标覆盖的阶段可能重叠，不能直接累加成端到端耗时。窗口摘要无法还原逐帧轨迹；"
                  "日志轮转或坏行可能使会话片段不完整。", ""])
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description="将 QuietDesk 双端诊断日志汇总为 Markdown（仅使用匿名性能字段）。")
    parser.add_argument("logs", nargs="+", type=Path, help="一个或多个导出的 JSONL 日志")
    parser.add_argument("--output", type=Path, help="保存 Markdown；省略时输出到终端")
    arguments = parser.parse_args()
    try:
        if arguments.output:
            for path in arguments.logs:
                if arguments.output.resolve() == path.resolve() or (
                        arguments.output.exists() and arguments.output.samefile(path)):
                    parser.error("报告路径不能覆盖输入日志")
        result = render_report([read_report(path) for path in arguments.logs])
        if arguments.output:
            arguments.output.write_text(result, encoding="utf-8")
        else:
            sys.stdout.write(result)
    except OSError as error:
        parser.exit(2, f"无法读取日志或保存报告：{error}\n")


if __name__ == "__main__":
    main()
