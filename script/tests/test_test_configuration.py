"""Execution boundaries: pure tests must never acquire an application host."""

import json
from pathlib import Path
import subprocess
import unittest
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[2]


class TestConfigurationTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        project = json.loads(subprocess.check_output([
            "plutil", "-convert", "json", "-o", "-",
            str(ROOT / "Latest.xcodeproj/project.pbxproj"),
        ]))
        cls.objects = project["objects"]
        cls.targets = {obj["name"]: obj for obj in cls.objects.values()
                       if obj["isa"] == "PBXNativeTarget"}
        cls.paths = {}

        def visit(identifier, parent):
            obj = cls.objects[identifier]
            if obj["isa"] == "PBXGroup":
                parent = parent / obj.get("path", "")
                for child in obj.get("children", []):
                    visit(child, parent)
            elif obj["isa"] == "PBXFileReference" and obj.get("sourceTree") == "<group>":
                cls.paths[identifier] = parent / obj["path"]

        visit(cls.objects[project["rootObject"]]["mainGroup"], ROOT)

    def sources(self, target):
        return {self.objects[build_file]["fileRef"]
                for phase in target["buildPhases"]
                if self.objects[phase]["isa"] == "PBXSourcesBuildPhase"
                for build_file in self.objects[phase]["files"]}

    def configurations(self, target):
        config_list = self.objects[target["buildConfigurationList"]]
        return [self.objects[identifier]["buildSettings"]
                for identifier in config_list["buildConfigurations"]]

    def test_unit_target_is_unhosted_and_reuses_real_production_sources(self):
        target = self.targets["Latest Unit Tests"]
        self.assertEqual(target["dependencies"], [])
        for config in self.configurations(target):
            self.assertFalse(config.get("TEST_HOST"))
            self.assertFalse(config.get("BUNDLE_LOADER"))
        sources = self.sources(target)
        production = {ref for ref in sources if self.paths[ref].is_relative_to(ROOT / "Latest")}
        self.assertTrue(production)
        self.assertLessEqual(production, self.sources(self.targets["Latest"]))
        for ref in sources:
            path = self.paths[ref]
            self.assertTrue(path.is_file(), path)
            self.assertNotIn("import SwiftUI", path.read_text(), path)
            self.assertNotIn("import AppKit", path.read_text(), path)
        scheme = ET.parse(ROOT / "Latest.xcodeproj/xcshareddata/xcschemes/Latest Unit Tests.xcscheme")
        self.assertEqual([ref.attrib["BlueprintName"] for ref in scheme.findall(".//BuildableReference")],
                         ["Latest Unit Tests", "Latest Unit Tests"])

    def test_moved_tests_have_one_owner_and_shared_fixtures_resolve_in_both_modules(self):
        unit = self.sources(self.targets["Latest Unit Tests"])
        hosted = self.sources(self.targets["Latest Tests"])
        shared_tests = {self.paths[ref].name for ref in unit & hosted
                        if self.paths[ref].is_relative_to(ROOT / "Tests")}
        self.assertEqual(shared_tests, {"ModelFixtures.swift"})
        for config in self.configurations(self.targets["Latest Tests"]):
            self.assertIn("LATEST_HOSTED_TESTS", config["SWIFT_ACTIVE_COMPILATION_CONDITIONS"])

    def test_hosted_plans_exclude_foreground_and_benchmarks_from_integration(self):
        def plan(name):
            return json.loads((ROOT / f"Tests/Latest{name}.xctestplan").read_text())

        integration, ui = plan("Integration"), plan("UI")
        selected_ui = set(ui["testTargets"][0]["selectedTests"])
        excluded = set(integration["testTargets"][0]["skippedTests"])
        self.assertTrue(selected_ui)
        self.assertLessEqual(selected_ui, excluded)
        self.assertIn("AppPerformanceTest", excluded)
        self.assertIn("ComplexityBenchmarkTest/testComplexityBenchmarks()", excluded)
        for name, foreground in (("Integration", "0"), ("UI", "1"),
                                 ("AppBenchmarks", "1"), ("ComplexityBenchmarks", "0")):
            data = plan(name)
            self.assertEqual(data["defaultOptions"]["environmentVariableEntries"],
                             [{"key": "LATEST_UI_TESTS", "value": foreground}])
        scheme = ET.parse(ROOT / "Latest.xcodeproj/xcshareddata/xcschemes/Latest.xcscheme")
        references = scheme.findall(".//TestPlanReference")
        self.assertEqual([ref.attrib["reference"] for ref in references if ref.attrib.get("default") == "YES"],
                         ["container:Tests/LatestIntegration.xctestplan"])
        for ref in references:
            self.assertTrue((ROOT / ref.attrib["reference"].removeprefix("container:")).is_file())


if __name__ == "__main__":
    unittest.main()
