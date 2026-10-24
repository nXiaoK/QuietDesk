import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "analyze-performance.py"
spec = importlib.util.spec_from_file_location("performance_report", SCRIPT)
report_module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = report_module
spec.loader.exec_module(report_module)


def window(**changes):
    record = {
        "timestamp": "2026-10-17T12:00:00Z", "event": "performanceWindow", "role": "viewer", "connectionID": 1,
        "performance": {"metric": "decode", "messageKind": 2, "unit": "microseconds", "count": 2,
                        "minimum": 0, "maximum": 4000, "mean": 2000, "p95UpperBound": 4000,
                        "worstIdentifier": 7, "windowMilliseconds": 5000},
    }
    record["performance"].update(changes)
    return record


class PerformanceReportTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def write(self, records, name="viewer.jsonl"):
        path = self.root / name
        path.write_text("\n".join(json.dumps(record) if not isinstance(record, str) else record
                                 for record in records) + "\n", encoding="utf-8")
        return path

    def test_weighted_mean_and_window_p95_are_not_averaged_as_percentiles(self):
        path = self.write([window(), window(count=8, minimum=3000, maximum=12000, mean=10000,
                                           p95UpperBound=12000, worstIdentifier=31)])
        report = report_module.read_report(path)
        aggregate = next(iter(report.groups.values()))
        self.assertEqual(aggregate.count, 10)
        self.assertEqual(aggregate.mean, 8400)
        self.assertEqual(aggregate.maximum, 12000)
        self.assertEqual(aggregate.maximum_window_p95, 12000)
        self.assertEqual((aggregate.worst_identifier, aggregate.worst_line), (31, 2))
        text = report_module.render_report([report])
        self.assertIn("8.400 ms", text)
        self.assertIn("12.000 ms", text)
        self.assertIn("各窗口 P95 上界的最大值", text)
        self.assertIn("不是全会话 P95", text)
        self.assertIn("31 / 第 2 行", text)

    def test_negotiated_media_metrics_and_message_kinds_are_preserved(self):
        records = [window(metric="mediaRoundTrip", messageKind=26),
                   window(metric="mediaReassembly", messageKind=27),
                   window(metric="mediaSwitch", messageKind=26),
                   window(metric="mediaDecodeInterval", messageKind=27),
                   window(metric="mediaRepairBytes", messageKind=28, unit="bytes"),
                   window(metric="mediaDatagramSentBytes", messageKind=27, unit="bytes"),
                   window(metric="mediaDatagramReceivedBytes", messageKind=27, unit="bytes"),
                   window(metric="mediaExpired", messageKind=27, unit="count"),
                   window(metric="mediaRecovery", messageKind=26, unit="count"),
                   window(metric="mediaTransport", messageKind=26, unit="count")]
        report = report_module.read_report(self.write(records))
        self.assertEqual(report.valid_windows, len(records))
        self.assertEqual(report.skipped_lines, 0)
        text = report_module.render_report([report])
        self.assertIn("mediaControl (26)", text)
        self.assertIn("mediaFrame (27)", text)
        self.assertIn("mediaFeedback (28)", text)

    def test_capture_and_encoder_metrics_preserve_units_without_inventing_missing_samples(self):
        records = [window(metric="captureInterval"), window(metric="encodeSubmit"),
                   window(metric="encoderDropped", unit="count", count=3, minimum=1, maximum=1,
                          mean=1, p95UpperBound=1)]
        report = report_module.read_report(self.write(records))
        self.assertEqual(report.valid_windows, 3)
        self.assertEqual(report.skipped_lines, 0)
        text = report_module.render_report([report])
        for metric in ("captureInterval", "encodeSubmit", "encoderDropped"):
            self.assertIn(metric, text)
        self.assertIn("1.000 count", text)
        self.assertNotIn("encoderHardware", text)
        invalid = report_module.read_report(self.write([window(metric="encoderDropped")], "wrong-unit.jsonl"))
        self.assertEqual(invalid.valid_windows, 0)
        self.assertEqual(invalid.skipped_lines, 1)

    def test_roles_connections_kinds_files_and_application_runs_stay_separate(self):
        host = window()
        host["role"] = "host"
        second = window()
        second["connectionID"] = 2
        records = [window(), host, second, window(messageKind=3), {"event": "applicationStarted"}, window()]
        first = report_module.read_report(self.write(records))
        other = report_module.read_report(self.write([window()], "host.jsonl"))
        self.assertEqual(len(first.groups), 5)
        self.assertEqual(len(other.groups), 1)
        self.assertTrue(all(value.count == 2 for value in first.groups.values()))
        text = report_module.render_report([first, other])
        self.assertIn("文件 1", text)
        self.assertIn("文件 2", text)
        self.assertIn("本地启动段 1", text)
        self.assertIn("起始片段（未见启动事件）", text)
        self.assertIn("连接 2", text)
        self.assertIn("共享端 host", text)
        self.assertIn("acknowledgement (3)", text)

    def test_independent_cursor_messages_are_preserved(self):
        report = report_module.read_report(self.write([window(messageKind=kind) for kind in (29, 30, 31)]))
        self.assertEqual(report.valid_windows, 3)
        self.assertEqual(report.skipped_lines, 0)
        text = report_module.render_report([report])
        for label in ("cursorControl (29)", "cursorShape (30)", "cursorPosition (31)"):
            self.assertIn(label, text)

    def test_malformed_unknown_and_boolean_fields_are_skipped_without_payload_reflection(self):
        invalid = ["{broken", "null", "[]", "{\"event\":\"performanceWindow\",\"event\":\"exportCompleted\"}"]
        for changes in ({"metric": "PRIVATE_METRIC"}, {"unit": "seconds"}, {"unit": "bytes"},
                        {"count": 0}, {"count": True}, {"mean": 1.5}, {"minimum": -1},
                        {"messageKind": True}, {"messageKind": 200}, {"messageKind": 256}, {"worstIdentifier": False},
                        {"windowMilliseconds": True}, {"mean": 2 ** 64}, {"minimum": 5000},
                        {"p95UpperBound": 4001},
                        {"extraPayload": "PRIVATE_SCREEN"}):
            invalid.append(window(**changes))
        for field, value in (("connectionID", True), ("role", "PRIVATE_ROLE"), ("timestamp", "PRIVATE_TIME")):
            record = window()
            record[field] = value
            invalid.append(record)
        extra = window()
        extra["clipboard"] = "PRIVATE_CLIPBOARD"
        invalid.extend([extra, {"event": "PRIVATE_EVENT", "password": "PRIVATE_PASSWORD"}])
        path = self.write([*invalid, {"event": "exportCompleted", "payload": "PRIVATE_OTHER"}, window()])
        report = report_module.read_report(path)
        self.assertEqual(report.skipped_lines, len(invalid))
        self.assertEqual(report.valid_windows, 1)
        self.assertEqual(report.other_events, 1)
        text = report_module.render_report([report])
        self.assertNotIn("PRIVATE_", text)

    def test_missing_data_is_not_reported_as_zero_and_recorded_zero_remains_a_sample(self):
        empty = report_module.read_report(self.write([{"event": "applicationStarted"}], "empty.jsonl"))
        text = report_module.render_report([empty])
        self.assertIn("缺少诊断数据", text)
        self.assertNotIn("0.000 ms", text)
        zero = window(count=1, minimum=0, maximum=0, mean=0, p95UpperBound=0)
        zero["performance"].pop("worstIdentifier")
        report = report_module.read_report(self.write([zero]))
        text = report_module.render_report([report])
        self.assertIn("0.000 ms", text)
        self.assertIn("未记录 / 第 1 行", text)
        self.assertIn("不代表整个流程无耗时", text)
        self.assertNotIn("缺少诊断数据", text)

    def test_byte_units_new_metrics_and_large_identifiers_survive_export(self):
        path = self.write([window(metric="encodedBytes", unit="bytes", count=1, minimum=2048, maximum=2048,
                                  mean=2048, p95UpperBound=2048, worstIdentifier=(1 << 64) - 1),
                           window(metric="decodePrepare"), window(metric="encodeCallbackQueue"),
                           window(metric="receiveHeaderWait", messageKind=None, worstIdentifier=None)])
        report = report_module.read_report(path)
        text = report_module.render_report([report])
        self.assertEqual(report.valid_windows, 4)
        self.assertIn("2.000 KiB", text)
        self.assertIn(str((1 << 64) - 1), text)
        self.assertIn("decodePrepare", text)
        self.assertIn("encodeCallbackQueue", text)
        self.assertIn("receiveHeaderWait", text)
        self.assertIn("包含静止等待和帧间隔", text)

    def test_metric_allowlist_matches_the_core_contract(self):
        source = (SCRIPT.parents[1] / "Sources/QuietDeskCore/PerformanceDiagnostics.swift").read_text()
        definition = source.split("public enum PerformanceMetric", 1)[1].split("public var unit", 1)[0]
        metrics = {name.strip() for declaration in re.findall(r"case ([^\n]+)", definition)
                   for name in declaration.split(",")}
        self.assertEqual(set(report_module.METRIC_UNITS), metrics)

    def test_tcp_report_values_use_transport_units_and_have_no_application_identifier(self):
        records = [window(metric=metric, unit=unit, count=1, minimum=value, maximum=value,
                          mean=value, p95UpperBound=value, messageKind=None, worstIdentifier=None)
                   for metric, unit, value in (("tcpSmoothedRTT", "microseconds", 3000),
                                               ("tcpMinimumRTT", "microseconds", 1000),
                                               ("tcpRTTVariance", "microseconds", 500),
                                               ("tcpReportDuration", "microseconds", 1000000),
                                               ("tcpRetransmittedBytes", "bytes", 0),
                                               ("tcpOutOfOrderBytes", "bytes", 2048),
                                               ("tcpSentBytes", "bytes", 4096),
                                               ("tcpReceivedBytes", "bytes", 1024))]
        invalid = window(metric="tcpRetransmittedBytes", unit="microseconds")
        report = report_module.read_report(self.write([*records, invalid]))
        self.assertEqual((report.valid_windows, report.skipped_lines), (8, 1))
        text = report_module.render_report([report])
        self.assertIn("3.000 ms", text)
        self.assertIn("0.500 ms", text)
        self.assertIn("0.000 KiB", text)
        self.assertIn("2.000 KiB", text)
        self.assertIn("1000.000 ms", text)
        self.assertIn("4.000 KiB", text)
        self.assertIn("1.000 KiB", text)
        self.assertIn("不是速率", text)
        self.assertIn("不能把窗口均值直接解释为吞吐", text)
        self.assertIn("不是逐包分位数", text)

    def test_oversized_and_invalid_utf8_lines_do_not_hide_following_windows(self):
        path = self.root / "damaged.jsonl"
        path.write_bytes(b"x" * (report_module.MAX_LINE_BYTES + 10) + b"\n\xff\n"
                         + json.dumps(window()).encode() + b"\n")
        report = report_module.read_report(path)
        self.assertEqual((report.skipped_lines, report.valid_windows), (2, 1))
        self.assertEqual(next(iter(report.groups.values())).worst_line, 3)

    def test_cli_writes_markdown_and_refuses_to_overwrite_input(self):
        path = self.write([window()])
        output = self.root / "report.md"
        subprocess.run([sys.executable, str(SCRIPT), str(path), "--output", str(output)], check=True)
        self.assertTrue(output.read_text().startswith("# QuietDesk 性能诊断摘要"))
        original = path.read_bytes()
        result = subprocess.run([sys.executable, str(SCRIPT), str(path), "--output", str(path)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(path.read_bytes(), original)

    def test_cli_refuses_an_existing_hardlink_to_an_input_log(self):
        path = self.write([window()])
        alias = self.root / "hardlink-report.md"
        os.link(path, alias)
        original = path.read_bytes()
        result = subprocess.run([sys.executable, str(SCRIPT), str(path), "--output", str(alias)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn("报告路径不能覆盖输入日志", result.stderr)
        self.assertEqual(path.read_bytes(), original)
        self.assertEqual(alias.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
