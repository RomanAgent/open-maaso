using System;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Xml;
using System.Xml.Linq;
using NUnit.Framework;
using UnityEditor;
using UnityEditor.Build.Reporting;
using UnityEngine;
using UnityEngine.Rendering;

public sealed class MaasoUnityLibraryExporterTests
{
    private const string ExporterTypeName =
        "Maaso.Avatar.Editor.MaasoUnityLibraryExporter, Assembly-CSharp-Editor";

    [TestCase(MeshDeformation.GPUBatched, BuildResult.Succeeded)]
    [TestCase(MeshDeformation.GPU, BuildResult.Succeeded)]
    [TestCase(MeshDeformation.CPU, BuildResult.Succeeded)]
    [TestCase(MeshDeformation.GPUBatched, BuildResult.Failed)]
    [TestCase(MeshDeformation.GPUBatched, BuildResult.Cancelled)]
    public void IOSMeshDeformationCandidateAppliesOnlyDuringBuildAndRestores(
        MeshDeformation original, BuildResult result)
    {
        WithMeshDeformationPolicyFixture(exportRoot =>
        {
            PlayerSettings.meshDeformation = original;
            bool graphicsJobs = PlayerSettings.graphicsJobs;
            GraphicsDeviceType[] graphicsApis = PlayerSettings.GetGraphicsAPIs(BuildTarget.iOS);
            int callbackCount = 0;
            var actual = InvokeMeshDeformationPolicy(BuildTarget.iOS, exportRoot, () =>
            {
                callbackCount++;
                Assert.That(PlayerSettings.meshDeformation, Is.EqualTo(MeshDeformation.GPU));
                Assert.That(PlayerSettings.graphicsJobs, Is.EqualTo(graphicsJobs));
                Assert.That(PlayerSettings.GetGraphicsAPIs(BuildTarget.iOS), Is.EqualTo(graphicsApis));
                var beforeBuild = ReadMeshDeformationReceipt(exportRoot);
                Assert.That(beforeBuild.unityBuildResult, Is.EqualTo("NotStarted"));
                Assert.That(beforeBuild.appliedPreBuildMeshDeformation, Is.EqualTo("GPU"));
                Assert.That(beforeBuild.appliedPreBuildMeshDeformationValue, Is.EqualTo((int)MeshDeformation.GPU));
                Assert.That(beforeBuild.originalSettingRestored, Is.False);
                if (result == BuildResult.Succeeded)
                {
                    Directory.CreateDirectory(Path.Combine(exportRoot, "Data"));
                    File.WriteAllText(Path.Combine(exportRoot, "Data", "boot.config"),
                        "gfx-threading-mode=4\nbuild-guid=0123456789abcdef0123456789abcdef\n");
                }
                return result;
            });

            Assert.That(actual, Is.EqualTo(result));
            Assert.That(callbackCount, Is.EqualTo(1));
            Assert.That(PlayerSettings.meshDeformation, Is.EqualTo(original));
            var receipt = ReadMeshDeformationReceipt(exportRoot);
            Assert.That(receipt.schemaVersion, Is.EqualTo(1));
            Assert.That(receipt.policy, Is.EqualTo("ios-unbatched-gpu-compatibility-candidate/v1"));
            Assert.That(receipt.compatibilityCandidate, Is.True);
            Assert.That(receipt.rootCauseConfirmed, Is.False);
            Assert.That(receipt.target, Is.EqualTo("iOS"));
            Assert.That(receipt.requestedMeshDeformation, Is.EqualTo("GPU"));
            Assert.That(receipt.requestedMeshDeformationValue, Is.EqualTo((int)MeshDeformation.GPU));
            Assert.That(receipt.originalMeshDeformation, Is.EqualTo(original.ToString()));
            Assert.That(receipt.originalMeshDeformationValue, Is.EqualTo((int)original));
            Assert.That(receipt.restoredMeshDeformation, Is.EqualTo(original.ToString()));
            Assert.That(receipt.restoredMeshDeformationValue, Is.EqualTo((int)original));
            Assert.That(receipt.originalSettingRestored, Is.True);
            Assert.That(receipt.unityBuildResult, Is.EqualTo(result.ToString()));
            Assert.That(receipt.exporterSourceSha256, Has.Length.EqualTo(64));
            Assert.That(DateTime.Parse(receipt.finishedAtUtc).ToUniversalTime(),
                Is.GreaterThanOrEqualTo(DateTime.Parse(receipt.startedAtUtc).ToUniversalTime()));
            Assert.That(File.Exists(Path.Combine(exportRoot, "Data", "maaso-ios-rendering-policy.json")), Is.False);
            if (result == BuildResult.Succeeded)
            {
                Assert.That(receipt.exportBootConfigSha256, Has.Length.EqualTo(64));
                Assert.That(receipt.exportBuildGuid, Is.EqualTo("0123456789abcdef0123456789abcdef"));
            }
            else Assert.That(receipt.exportBuildGuid, Is.Null.Or.Empty);
        });
    }

    [Test]
    public void IOSMeshDeformationCandidateRestoresWhenBuildThrows()
    {
        WithMeshDeformationPolicyFixture(exportRoot =>
        {
            PlayerSettings.meshDeformation = MeshDeformation.GPUBatched;
            var failure = new InvalidOperationException("fixture build interrupted");
            var error = Assert.Throws<TargetInvocationException>(() =>
                InvokeMeshDeformationPolicy(BuildTarget.iOS, exportRoot, () =>
                {
                    Assert.That(PlayerSettings.meshDeformation, Is.EqualTo(MeshDeformation.GPU));
                    throw failure;
                }));
            Assert.That(error.InnerException, Is.SameAs(failure));
            Assert.That(PlayerSettings.meshDeformation, Is.EqualTo(MeshDeformation.GPUBatched));
            var receipt = ReadMeshDeformationReceipt(exportRoot);
            Assert.That(receipt.unityBuildResult, Is.EqualTo("Exception"));
            Assert.That(receipt.originalSettingRestored, Is.True);
            Assert.That(receipt.restoredMeshDeformation, Is.EqualTo("GPUBatched"));
        });
    }

    [TestCase(BuildTarget.Android)]
    [TestCase(BuildTarget.StandaloneOSX)]
    [TestCase(BuildTarget.StandaloneWindows64)]
    [TestCase(BuildTarget.WebGL)]
    public void NonIOSBuildDoesNotApplyCandidateOrWriteReceipt(BuildTarget target)
    {
        WithMeshDeformationPolicyFixture(exportRoot =>
        {
            PlayerSettings.meshDeformation = MeshDeformation.GPUBatched;
            int callbackCount = 0;
            var result = InvokeMeshDeformationPolicy(target, exportRoot, () =>
            {
                callbackCount++;
                Assert.That(PlayerSettings.meshDeformation, Is.EqualTo(MeshDeformation.GPUBatched));
                return BuildResult.Succeeded;
            });
            Assert.That(result, Is.EqualTo(BuildResult.Succeeded));
            Assert.That(callbackCount, Is.EqualTo(1));
            Assert.That(PlayerSettings.meshDeformation, Is.EqualTo(MeshDeformation.GPUBatched));
            Assert.That(Directory.Exists(exportRoot), Is.False);
        });
    }

    private static BuildResult InvokeMeshDeformationPolicy(
        BuildTarget target, string exportRoot, Func<BuildResult> build)
    {
        var method = RequireExporterType().GetMethod("RunBuildWithIOSMeshDeformationPolicy",
            BindingFlags.NonPublic | BindingFlags.Static);
        Assert.That(method, Is.Not.Null);
        return (BuildResult)method.Invoke(null, new object[] { target, exportRoot, build });
    }

    private static void WithMeshDeformationPolicyFixture(Action<string> action)
    {
        string exportRoot = Path.Combine(Path.GetTempPath(), "maaso-ios-gpu-policy-" + Guid.NewGuid().ToString("N"));
        const string settingsPath = "ProjectSettings/ProjectSettings.asset";
        byte[] settingsBytes = File.ReadAllBytes(settingsPath);
        MeshDeformation original = PlayerSettings.meshDeformation;
        try { action(exportRoot); }
        finally
        {
            PlayerSettings.meshDeformation = original;
            File.WriteAllBytes(settingsPath, settingsBytes);
            if (Directory.Exists(exportRoot)) Directory.Delete(exportRoot, true);
        }
    }

    private static MeshDeformationReceipt ReadMeshDeformationReceipt(string exportRoot) =>
        JsonUtility.FromJson<MeshDeformationReceipt>(File.ReadAllText(
            Path.Combine(exportRoot, "maaso-ios-rendering-policy.json")));

    [Serializable]
    private sealed class MeshDeformationReceipt
    {
        public int schemaVersion, requestedMeshDeformationValue, originalMeshDeformationValue;
        public int appliedPreBuildMeshDeformationValue, restoredMeshDeformationValue;
        public bool compatibilityCandidate, rootCauseConfirmed, originalSettingRestored;
        public string policy, target, startedAtUtc, finishedAtUtc, requestedMeshDeformation;
        public string originalMeshDeformation, appliedPreBuildMeshDeformation, restoredMeshDeformation;
        public string unityBuildResult, exporterSourceSha256, exportBootConfigSha256, exportBuildGuid;
    }

    [Test]
    public void IOSExportSanitizerRemovesRepeatedBuildPhaseReferences()
    {
        string exportRoot = Path.Combine(
            Path.GetTempPath(),
            "maaso-ios-export-sanitizer-" + Guid.NewGuid().ToString("N"));
        string projectDirectory = Path.Combine(
            exportRoot,
            "Unity-iPhone.xcodeproj");
        string projectPath = Path.Combine(projectDirectory, "project.pbxproj");
        Directory.CreateDirectory(projectDirectory);
        File.WriteAllText(projectPath, DuplicateBuildPhaseProject());

        try
        {
            Type exporterType = Type.GetType(ExporterTypeName);
            Assert.That(exporterType, Is.Not.Null, ExporterTypeName);
            MethodInfo sanitizer = exporterType.GetMethod(
                "SanitizeIOSDuplicateBuildPhases",
                BindingFlags.NonPublic | BindingFlags.Static);
            Assert.That(
                sanitizer,
                Is.Not.Null,
                "Every Unity iOS export path must sanitize duplicate build phase references.");

            object removed = sanitizer.Invoke(null, new object[] { exportRoot });
            string sanitizedProject = File.ReadAllText(projectPath);

            Assert.That(removed, Is.EqualTo(1));
            Assert.That(
                CountOccurrences(
                    sanitizedProject,
                    "C62A2A42F32E085EF849CF0B /* ShellScript */,"),
                Is.EqualTo(1));
            Assert.That(
                sanitizedProject,
                Does.Contain("7F4E059C2717216D00A2CBE4 /* Sources */,"));
        }
        finally
        {
            Directory.Delete(exportRoot, true);
        }
    }

    [Test]
    public void WindowsExportUsesStandaloneTargetGroup()
    {
        Type exporterType = RequireExporterType();
        MethodInfo resolver = exporterType.GetMethod(
            "ResolveTargetGroup",
            BindingFlags.NonPublic | BindingFlags.Static);

        Assert.That(resolver, Is.Not.Null);
        object group = resolver.Invoke(
            null,
            new object[] { BuildTarget.StandaloneWindows64 });

        Assert.That(group, Is.EqualTo(BuildTargetGroup.Standalone));
        Assert.That(
            exporterType.GetMethod(
                "ExportWindows64",
                BindingFlags.Public | BindingFlags.Static),
            Is.Not.Null);
    }

    [Test]
    public void WindowsExportValidatorRequiresPlayerLibraryAndData()
    {
        string exportRoot = Path.Combine(
            Path.GetTempPath(),
            "maaso-windows-export-validator-" + Guid.NewGuid().ToString("N"));
        string executablePath = Path.Combine(exportRoot, "MaasoAvatar.exe");
        Directory.CreateDirectory(exportRoot);

        try
        {
            Type exporterType = RequireExporterType();
            MethodInfo validator = exporterType.GetMethod(
                "ValidateWindowsPlayerExport",
                BindingFlags.NonPublic | BindingFlags.Static);
            Assert.That(validator, Is.Not.Null);

            TargetInvocationException missing = Assert.Throws<TargetInvocationException>(
                () => validator.Invoke(null, new object[] { executablePath }));
            Assert.That(missing.InnerException, Is.TypeOf<InvalidOperationException>());

            File.WriteAllBytes(executablePath, Array.Empty<byte>());
            File.WriteAllBytes(
                Path.Combine(exportRoot, "UnityPlayer.dll"),
                Array.Empty<byte>());
            Directory.CreateDirectory(Path.Combine(exportRoot, "MaasoAvatar_Data"));

            Assert.DoesNotThrow(
                () => validator.Invoke(null, new object[] { executablePath }));
        }
        finally
        {
            Directory.Delete(exportRoot, true);
        }
    }

    [Test]
    public void MacOSSidecarUsesStandaloneTargetAndValidatesAppBundle()
    {
        string exportRoot = Path.Combine(
            Path.GetTempPath(),
            "maaso-macos-sidecar-validator-" + Guid.NewGuid().ToString("N"));
        string appPath = Path.Combine(exportRoot, "MaasoAvatar.app");
        string executablePath = Path.Combine(
            appPath,
            "Contents",
            "MacOS",
            "MaasoAvatar");
        string dataPath = Path.Combine(
            appPath,
            "Contents",
            "Resources",
            "Data");
        string pluginPath = Path.Combine(
            appPath,
            "Contents",
            "PlugIns",
            "MaasoDesktopAvatarPortalBridge.bundle",
            "Contents",
            "MacOS",
            "MaasoDesktopAvatarPortalBridge");
        string protocolFingerprintPath = Path.Combine(
            dataPath,
            "maaso-sidecar-protocol.sha256");
        Directory.CreateDirectory(Path.GetDirectoryName(executablePath));
        Directory.CreateDirectory(dataPath);
        Directory.CreateDirectory(Path.GetDirectoryName(pluginPath));
        File.WriteAllBytes(executablePath, Array.Empty<byte>());
        File.WriteAllBytes(pluginPath, Array.Empty<byte>());
        File.WriteAllText(protocolFingerprintPath, new string('0', 64));
        File.WriteAllText(
            Path.Combine(appPath, "Contents", "Info.plist"),
            SidecarInfoPlist("<key>LSUIElement</key><true/>"));

        try
        {
            Type exporterType = RequireExporterType();
            MethodInfo targetResolver = exporterType.GetMethod(
                "ResolveTargetGroup",
                BindingFlags.NonPublic | BindingFlags.Static);
            MethodInfo validator = exporterType.GetMethod(
                "ValidateMacOSSidecarExport",
                BindingFlags.NonPublic | BindingFlags.Static);

            Assert.That(targetResolver, Is.Not.Null);
            Assert.That(validator, Is.Not.Null);
            Assert.That(
                targetResolver.Invoke(
                    null,
                    new object[] { BuildTarget.StandaloneOSX }),
                Is.EqualTo(BuildTargetGroup.Standalone));
            Assert.DoesNotThrow(
                () => validator.Invoke(null, new object[] { appPath }));
            Assert.That(
                exporterType.GetMethod(
                    "ExportMacOSSidecar",
                    BindingFlags.Public | BindingFlags.Static),
                Is.Not.Null);
        }
        finally
        {
            Directory.Delete(exportRoot, true);
        }
    }

    [TestCase("")]
    [TestCase("<key>LSUIElement</key><false/>")]
    [TestCase("<key>LSUIElement</key><string>true</string>")]
    [TestCase("<key>LSUIElement</key><true/><key>LSBackgroundOnly</key><true/>")]
    public void MacOSSidecarPlistPatchPreservesUnityStartupAndIsIdempotent(string policy)
    {
        WithMacOSSidecarExport(appPath =>
        {
            string plistPath = Path.Combine(appPath, "Contents", "Info.plist");
            File.WriteAllText(plistPath, SidecarInfoPlist(policy).Replace(
                "com.futurpals.maaso.avatar-sidecar", "com.DefaultCompany.Maaso"));
            var before = ReadSidecarPlist(plistPath);

            InvokeExporter("PatchMacOSSidecarInfoPlist", appPath);
            byte[] firstPatch = File.ReadAllBytes(plistPath);
            var after = ReadSidecarPlist(plistPath);
            Assert.That(PlistValue(after, "LSUIElement").Name.LocalName, Is.EqualTo("true"));
            Assert.That(PlistValue(after, "CFBundleIdentifier").Value,
                Is.EqualTo("com.futurpals.maaso.avatar-sidecar"));
            Assert.That(PlistValue(after, "LSBackgroundOnly"), Is.Null);
            foreach (var key in before.Root.Element("dict").Elements("key"))
            {
                if (new[] { "LSUIElement", "LSBackgroundOnly", "CFBundleIdentifier" }
                    .Contains(key.Value))
                {
                    continue;
                }
                Assert.That(XNode.DeepEquals(
                    PlistValue(before, key.Value), PlistValue(after, key.Value)),
                    Is.True, "Unrelated Unity plist field changed: " + key.Value);
            }
            Assert.That(PlistValue(after, "NSPrincipalClass").Value,
                Is.EqualTo("PlayerApplication"));
            Assert.That(PlistValue(after, "NSMainNibFile").Value,
                Is.EqualTo("MainMenu"));
            Assert.That(XNode.DeepEquals(before.DocumentType, after.DocumentType), Is.True);
            InvokeExporter("ValidateMacOSSidecarExport", appPath);

            InvokeExporter("PatchMacOSSidecarInfoPlist", appPath);
            Assert.That(File.ReadAllBytes(plistPath), Is.EqualTo(firstPatch),
                "A second patch must preserve the already-correct signed content bytes.");
        });
    }

    [TestCase("missing-policy")]
    [TestCase("false-policy")]
    [TestCase("string-policy")]
    [TestCase("nonempty-policy")]
    [TestCase("missing-id")]
    [TestCase("wrong-id")]
    [TestCase("non-string-id")]
    [TestCase("background-only")]
    [TestCase("background-only-false")]
    [TestCase("duplicate-policy")]
    [TestCase("duplicate-id")]
    public void MacOSSidecarValidatorRejectsInvalidHelperIdentity(string defect)
    {
        WithMacOSSidecarExport(appPath =>
        {
            string plistPath = Path.Combine(appPath, "Contents", "Info.plist");
            var plist = ReadSidecarPlist(plistPath);
            var dictionary = plist.Root.Element("dict");
            switch (defect)
            {
                case "missing-policy":
                    RemovePlistValue(plist, "LSUIElement");
                    break;
                case "false-policy":
                    PlistValue(plist, "LSUIElement").ReplaceWith(new XElement("false"));
                    break;
                case "string-policy":
                    PlistValue(plist, "LSUIElement").ReplaceWith(new XElement("string", "true"));
                    break;
                case "nonempty-policy":
                    PlistValue(plist, "LSUIElement").Value = "true";
                    break;
                case "missing-id":
                    RemovePlistValue(plist, "CFBundleIdentifier");
                    break;
                case "wrong-id":
                    PlistValue(plist, "CFBundleIdentifier").Value = "com.DefaultCompany.Maaso";
                    break;
                case "non-string-id":
                    PlistValue(plist, "CFBundleIdentifier").ReplaceWith(new XElement("true"));
                    break;
                case "background-only":
                case "background-only-false":
                    dictionary.Add(new XElement("key", "LSBackgroundOnly"),
                        new XElement(defect == "background-only" ? "true" : "false"));
                    break;
                case "duplicate-policy":
                    dictionary.Add(new XElement("key", "LSUIElement"), new XElement("true"));
                    break;
                case "duplicate-id":
                    dictionary.Add(new XElement("key", "CFBundleIdentifier"),
                        new XElement("string", "com.futurpals.maaso.avatar-sidecar"));
                    break;
            }
            plist.Save(plistPath);
            AssertInvalidSidecar("ValidateMacOSSidecarExport", appPath);
        });
    }

    [TestCase("<plist><array/></plist>")]
    [TestCase("<plist><dict/><dict/></plist>")]
    [TestCase("<plist><dict><key>LSUIElement</key></dict></plist>")]
    [TestCase("<plist><dict><string>unkeyed</string><true/></dict></plist>")]
    [TestCase("<plist><dict><key>LSUIElement</key><key>other</key></dict></plist>")]
    [TestCase("<plist><dict><key>LSUIElement</key><true/><key>LSUIElement</key><false/></dict></plist>")]
    [TestCase("<plist><dict>")]
    [TestCase("<!DOCTYPE plist [<!ENTITY injected 'invalid'>]><plist><dict/></plist>")]
    public void MacOSSidecarRejectsMalformedPlistWithoutRewritingIt(string malformed)
    {
        WithMacOSSidecarExport(appPath =>
        {
            string plistPath = Path.Combine(appPath, "Contents", "Info.plist");
            File.WriteAllText(plistPath, malformed);
            AssertInvalidSidecar("PatchMacOSSidecarInfoPlist", appPath);
            Assert.That(File.ReadAllText(plistPath), Is.EqualTo(malformed));
            AssertInvalidSidecar("ValidateMacOSSidecarExport", appPath);
        });
    }

    [Test]
    public void MacOSSidecarPatchDoesNotResolveExternalDtd()
    {
        WithMacOSSidecarExport(appPath =>
        {
            string plistPath = Path.Combine(appPath, "Contents", "Info.plist");
            string poisonDtdPath = Path.Combine(appPath, "must-not-be-read.dtd");
            File.WriteAllText(poisonDtdPath, "This is not a DTD; resolving it must fail.");
            var plist = ReadSidecarPlist(plistPath);
            plist.DocumentType.ReplaceWith(new XDocumentType(
                "plist", null, new Uri(poisonDtdPath).AbsoluteUri, null));
            PlistValue(plist, "LSUIElement").ReplaceWith(new XElement("false"));
            plist.Save(plistPath);

            Assert.DoesNotThrow(() => InvokeExporter("PatchMacOSSidecarInfoPlist", appPath));
            Assert.DoesNotThrow(() => InvokeExporter("ValidateMacOSSidecarExport", appPath));
            Assert.That(ReadSidecarPlist(plistPath).DocumentType.SystemId,
                Is.EqualTo(new Uri(poisonDtdPath).AbsoluteUri));
        });
    }

    [Test]
    public void MacOSSidecarRequiresInfoPlistEvenWhenPlayerFilesExist()
    {
        WithMacOSSidecarExport(appPath =>
        {
            string plistPath = Path.Combine(appPath, "Contents", "Info.plist");
            File.Delete(plistPath);
            AssertInvalidSidecar("ValidateMacOSSidecarExport", appPath);
            AssertInvalidSidecar("PatchMacOSSidecarInfoPlist", appPath);
            Assert.That(File.Exists(plistPath), Is.False,
                "Never synthesize a plist that loses Unity's original startup fields.");
        });
    }

    [Test]
    public void MacOSSidecarPatchRoundTripsThroughAppleParser()
    {
        RequireApplePlistParser();
        WithMacOSSidecarExport(appPath =>
        {
            string path = Path.Combine(appPath, "Contents", "Info.plist");
            File.WriteAllText(path, SidecarInfoPlist("<key>LSUIElement</key><false/>"));
            AssertApplePlistAccepted(path, true);

            InvokeExporter("PatchMacOSSidecarInfoPlist", appPath);
            AssertApplePlistAccepted(path, true);
            byte[] patched = File.ReadAllBytes(path);
            Assert.That(File.ReadAllText(path), Does.Not.Contain("[]>") );
            InvokeExporter("ValidateMacOSSidecarExport", appPath);
            InvokeExporter("PatchMacOSSidecarInfoPlist", appPath);
            AssertApplePlistAccepted(path, true);
            Assert.That(File.ReadAllBytes(path), Is.EqualTo(patched));
        });
    }

    [Test]
    public void MacOSSidecarValidatorRejectsEmptyDtdSubsetAndPatchRepairsIt()
    {
        RequireApplePlistParser();
        WithMacOSSidecarExport(appPath =>
        {
            string path = Path.Combine(appPath, "Contents", "Info.plist");
            File.WriteAllText(path, SidecarInfoPlist("<key>LSUIElement</key><true/>")
                .Replace("PropertyList-1.0.dtd\">", "PropertyList-1.0.dtd\"[]>"));
            Assert.DoesNotThrow(() => ReadSidecarPlist(path),
                "This regression is valid XML but invalid to Apple's plist parser.");
            AssertApplePlistAccepted(path, false);
            AssertInvalidSidecar("ValidateMacOSSidecarExport", appPath);

            InvokeExporter("PatchMacOSSidecarInfoPlist", appPath);
            AssertApplePlistAccepted(path, true);
            InvokeExporter("ValidateMacOSSidecarExport", appPath);
            Assert.That(PlistValue(ReadSidecarPlist(path), "NSPrincipalClass").Value,
                Is.EqualTo("PlayerApplication"));
        });
    }

    private static void RequireApplePlistParser()
    {
        if (Application.platform != RuntimePlatform.OSXEditor)
        {
            Assert.Ignore("The real Apple plist parser is available only on macOS.");
        }
        Assert.That(File.Exists("/usr/bin/plutil"), Is.True);
    }

    [Test]
    public void MacOSNativePortalImporterPersistsStartupPreloadOnlyForMacPlayer()
    {
        WithNativeBundleImporter(importer =>
        {
            importer.SetCompatibleWithAnyPlatform(true);
            importer.SetCompatibleWithEditor(true);
            importer.SetCompatibleWithPlatform(BuildTarget.Android, true);
            importer.SetCompatibleWithPlatform(BuildTarget.iOS, true);
            importer.SetCompatibleWithPlatform(BuildTarget.StandaloneWindows64, true);

            InvokeExporterMethod("ConfigureMacOSNativePortalPluginImporter", importer);
            importer.SaveAndReimport();
            var restored = AssetImporter.GetAtPath(importer.assetPath) as PluginImporter;
            Assert.That(restored, Is.Not.Null);
            Assert.That(restored.isNativePlugin, Is.True);
            Assert.That(restored.isPreloaded, Is.True);
            Assert.That(restored.GetCompatibleWithAnyPlatform(), Is.False);
            Assert.That(restored.GetCompatibleWithEditor(), Is.False);
            Assert.That(restored.GetCompatibleWithPlatform(BuildTarget.StandaloneOSX), Is.True);
            Assert.That(restored.GetPlatformData(BuildTarget.StandaloneOSX, "CPU"),
                Is.EqualTo("AnyCPU"));
            foreach (var target in new[] { BuildTarget.iOS, BuildTarget.Android,
                BuildTarget.WebGL, BuildTarget.StandaloneWindows64, BuildTarget.StandaloneLinux64 })
            {
                Assert.That(restored.GetCompatibleWithPlatform(target), Is.False, target.ToString());
            }
            InvokeExporterMethod("ValidateMacOSNativePortalPluginImporter", restored);
            string configuredMetadata = File.ReadAllText(restored.assetPath + ".meta");
            InvokeExporterMethod("ConfigureMacOSNativePortalPluginImporter", restored);
            restored.SaveAndReimport();
            Assert.That(File.ReadAllText(restored.assetPath + ".meta"), Is.EqualTo(configuredMetadata));
        });
    }

    [TestCase("on-demand")]
    [TestCase("editor")]
    [TestCase("any-platform")]
    [TestCase("missing-macos")]
    [TestCase("android")]
    [TestCase("wrong-cpu")]
    public void MacOSNativePortalImporterRejectsUnsafeOrLateLoading(string defect)
    {
        WithNativeBundleImporter(importer =>
        {
            InvokeExporterMethod("ConfigureMacOSNativePortalPluginImporter", importer);
            switch (defect)
            {
                case "on-demand": importer.isPreloaded = false; break;
                case "editor": importer.SetCompatibleWithEditor(true); break;
                case "any-platform": importer.SetCompatibleWithAnyPlatform(true); break;
                case "missing-macos": importer.SetCompatibleWithPlatform(BuildTarget.StandaloneOSX, false); break;
                case "android": importer.SetCompatibleWithPlatform(BuildTarget.Android, true); break;
                case "wrong-cpu": importer.SetPlatformData(BuildTarget.StandaloneOSX, "CPU", "ARM64"); break;
            }
            var error = Assert.Throws<TargetInvocationException>(() =>
                InvokeExporterMethod("ValidateMacOSNativePortalPluginImporter", importer));
            Assert.That(error.InnerException, Is.TypeOf<InvalidOperationException>());
        });
    }

    [Test]
    public void MacOSNativePortalSourceIsNotASecondPlayerPlugin()
    {
        const string sourcePath = "Assets/Plugins/macOS/MaasoDesktopAvatarPortalBridge.mm";
        Assert.That(File.Exists(sourcePath), Is.True, "clang still needs the original source.");
        var importer = AssetImporter.GetAtPath(sourcePath) as PluginImporter;
        Assert.That(importer, Is.Not.Null);
        Assert.That(importer.isPreloaded, Is.False);
        Assert.That(importer.GetCompatibleWithAnyPlatform(), Is.False);
        Assert.That(importer.GetCompatibleWithEditor(), Is.False);
        Assert.That(importer.GetCompatibleWithPlatform(BuildTarget.StandaloneOSX), Is.False);
    }

    private static void WithNativeBundleImporter(Action<PluginImporter> action)
    {
        if (Application.platform != RuntimePlatform.OSXEditor)
        {
            Assert.Ignore("This fixture imports a real macOS native bundle.");
        }
        string suffix = Guid.NewGuid().ToString("N");
        string assetRoot = "Assets/MaasoPortalImporterTest_" + suffix;
        string bundlePath = assetRoot + "/MaasoPreloadFixture.bundle";
        string sourcePath = Path.Combine(Path.GetTempPath(), "maaso-preload-" + suffix + ".c");
        AssetDatabase.CreateFolder("Assets", "MaasoPortalImporterTest_" + suffix);
        try
        {
            string executablePath = bundlePath + "/Contents/MacOS/MaasoPreloadFixture";
            Directory.CreateDirectory(Path.GetDirectoryName(executablePath));
            File.WriteAllText(bundlePath + "/Contents/Info.plist",
                "<plist version=\"1.0\"><dict><key>CFBundleExecutable</key><string>MaasoPreloadFixture</string>" +
                "<key>CFBundleIdentifier</key><string>com.futurpals.tests.preload</string>" +
                "<key>CFBundlePackageType</key><string>BNDL</string></dict></plist>");
            // Inert code: importing this fixture cannot touch Unity, AppKit or windows.
            File.WriteAllText(sourcePath, "int MaasoPreloadFixture(void) { return 1; }\n");
            InvokeExporterMethod("RunFixedBuildTool", "/usr/bin/xcrun", new[]
            {
                "--sdk", "macosx", "clang", "-bundle", "-arch", "arm64", "-arch", "x86_64",
                sourcePath, "-o", executablePath
            }, "Could not compile the inert native importer fixture.");
            AssetDatabase.ImportAsset(bundlePath,
                ImportAssetOptions.ForceSynchronousImport | ImportAssetOptions.ForceUpdate);
            var importer = AssetImporter.GetAtPath(bundlePath) as PluginImporter;
            Assert.That(importer, Is.Not.Null);
            Assert.That(importer.isNativePlugin, Is.True);
            action(importer);
        }
        finally
        {
            AssetDatabase.DeleteAsset(assetRoot);
            if (File.Exists(sourcePath)) File.Delete(sourcePath);
        }
    }

    private static void InvokeExporterMethod(string methodName, params object[] arguments)
    {
        var method = RequireExporterType().GetMethod(
            methodName, BindingFlags.NonPublic | BindingFlags.Static);
        Assert.That(method, Is.Not.Null, methodName);
        method.Invoke(null, arguments);
    }

    private static void AssertApplePlistAccepted(string path, bool accepted)
    {
        var startInfo = new System.Diagnostics.ProcessStartInfo
        {
            FileName = "/usr/bin/plutil",
            Arguments = "-lint -- \"" + path.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"",
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        using (var process = System.Diagnostics.Process.Start(startInfo))
        {
            Assert.That(process, Is.Not.Null);
            string output = process.StandardOutput.ReadToEnd() + process.StandardError.ReadToEnd();
            process.WaitForExit();
            Assert.That(process.ExitCode == 0, Is.EqualTo(accepted), output);
        }
    }

    private static void WithMacOSSidecarExport(Action<string> action)
    {
        string exportRoot = Path.Combine(Path.GetTempPath(),
            "maaso-sidecar-plist-" + Guid.NewGuid().ToString("N"));
        string appPath = Path.Combine(exportRoot, "MaasoAvatar.app");
        foreach (string relativePath in new[]
        {
            "Contents/MacOS/MaasoAvatar",
            "Contents/PlugIns/MaasoDesktopAvatarPortalBridge.bundle/Contents/MacOS/MaasoDesktopAvatarPortalBridge",
            "Contents/Resources/Data/maaso-sidecar-protocol.sha256"
        })
        {
            string filePath = Path.Combine(appPath, relativePath);
            Directory.CreateDirectory(Path.GetDirectoryName(filePath));
            File.WriteAllText(filePath, new string('0', 64));
        }
        File.WriteAllText(Path.Combine(appPath, "Contents", "Info.plist"),
            SidecarInfoPlist("<key>LSUIElement</key><true/>"));
        try
        {
            action(appPath);
        }
        finally
        {
            Directory.Delete(exportRoot, true);
        }
    }

    private static string SidecarInfoPlist(string policy)
    {
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" +
            "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n" +
            "<plist version=\"1.0\"><dict>" +
            "<key>CFBundleIdentifier</key><string>com.futurpals.maaso.avatar-sidecar</string>" +
            "<key>CFBundleExecutable</key><string>MaasoAvatar</string>" +
            "<key>NSPrincipalClass</key><string>PlayerApplication</string>" +
            "<key>NSMainNibFile</key><string>MainMenu</string>" +
            "<key>NSHighResolutionCapable</key><true/>" +
            "<key>UnityCustomSettings</key><dict><key>Renderer</key><string>Metal</string>" +
            "<key>Scale</key><real>1.5</real><key>Modes</key><array><string>普通 &amp; 高质量</string></array></dict>" +
            policy + "</dict></plist>";
    }

    private static XDocument ReadSidecarPlist(string path)
    {
        using (var reader = XmlReader.Create(path,
            new XmlReaderSettings { XmlResolver = null, DtdProcessing = DtdProcessing.Parse }))
        {
            return XDocument.Load(reader);
        }
    }

    private static XElement PlistValue(XDocument document, string key)
    {
        return document.Root.Element("dict").Elements("key")
            .SingleOrDefault(element => element.Value == key)?.ElementsAfterSelf().First();
    }

    private static void RemovePlistValue(XDocument document, string key)
    {
        var value = PlistValue(document, key);
        value.ElementsBeforeSelf("key").Last().Remove();
        value.Remove();
    }

    private static void InvokeExporter(string methodName, string appPath)
    {
        var method = RequireExporterType().GetMethod(
            methodName, BindingFlags.NonPublic | BindingFlags.Static);
        Assert.That(method, Is.Not.Null, methodName);
        method.Invoke(null, new object[] { appPath });
    }

    private static void AssertInvalidSidecar(string methodName, string appPath)
    {
        var error = Assert.Throws<TargetInvocationException>(
            () => InvokeExporter(methodName, appPath));
        Assert.That(error.InnerException, Is.TypeOf<InvalidOperationException>());
    }

    [Test]
    public void WebGLExportUsesWebGLTargetAndStableBuildSupportName()
    {
        Type exporterType = RequireExporterType();
        MethodInfo targetResolver = exporterType.GetMethod(
            "ResolveTargetGroup",
            BindingFlags.NonPublic | BindingFlags.Static);
        MethodInfo supportResolver = exporterType.GetMethod(
            "ResolveBuildSupportName",
            BindingFlags.NonPublic | BindingFlags.Static);

        Assert.That(targetResolver, Is.Not.Null);
        Assert.That(supportResolver, Is.Not.Null);
        Assert.That(
            targetResolver.Invoke(null, new object[] { BuildTarget.WebGL }),
            Is.EqualTo(BuildTargetGroup.WebGL));
        Assert.That(
            supportResolver.Invoke(null, new object[] { BuildTarget.WebGL }),
            Is.EqualTo("WebGL Build Support"));
        Assert.That(
            exporterType.GetMethod(
                "ExportWebGL",
                BindingFlags.Public | BindingFlags.Static),
            Is.Not.Null);
    }

    [Test]
    public void WebGLConfigurationIsPortableTransparentAndRestorable()
    {
        Type exporterType = RequireExporterType();
        Type backupType = exporterType.GetNestedType(
            "WebGLSettingsBackup",
            BindingFlags.NonPublic);
        MethodInfo configure = exporterType.GetMethod(
            "ConfigureWebGLPlayerSettings",
            BindingFlags.NonPublic | BindingFlags.Static);
        Assert.That(backupType, Is.Not.Null);
        Assert.That(configure, Is.Not.Null);
        MethodInfo capture = backupType.GetMethod(
            "Capture",
            BindingFlags.Public | BindingFlags.Static);
        MethodInfo restore = backupType.GetMethod(
            "Restore",
            BindingFlags.Public | BindingFlags.Instance);
        Assert.That(capture, Is.Not.Null);
        Assert.That(restore, Is.Not.Null);
        bool originalFramebufferAlpha =
            PlayerSettings.preserveFramebufferAlpha;
        object backup = capture.Invoke(null, Array.Empty<object>());

        try
        {
            configure.Invoke(null, Array.Empty<object>());

            Assert.That(PlayerSettings.preserveFramebufferAlpha, Is.True);
            Assert.That(
                PlayerSettings.WebGL.compressionFormat,
                Is.EqualTo(WebGLCompressionFormat.Disabled));
            Assert.That(PlayerSettings.WebGL.decompressionFallback, Is.False);
            Assert.That(PlayerSettings.WebGL.threadsSupport, Is.False);
            Assert.That(PlayerSettings.WebGL.nameFilesAsHashes, Is.False);
            Assert.That(PlayerSettings.WebGL.dataCaching, Is.True);
        }
        finally
        {
            restore.Invoke(backup, Array.Empty<object>());
            Assert.That(
                PlayerSettings.preserveFramebufferAlpha,
                Is.EqualTo(originalFramebufferAlpha));
        }
    }

    [Test]
    public void WebGLExportValidatorAndManifestUseStableRelativeFiles()
    {
        string exportRoot = Path.Combine(
            Path.GetTempPath(),
            "maaso-webgl-export-validator-" + Guid.NewGuid().ToString("N"));
        CreateWebGLPlayerFiles(exportRoot);

        try
        {
            Type exporterType = RequireExporterType();
            MethodInfo validator = exporterType.GetMethod(
                "ValidateWebGLPlayerExport",
                BindingFlags.NonPublic | BindingFlags.Static);
            MethodInfo manifestWriter = exporterType.GetMethod(
                "WriteWebGLBuildManifest",
                BindingFlags.NonPublic | BindingFlags.Static);

            Assert.That(validator, Is.Not.Null);
            Assert.That(manifestWriter, Is.Not.Null);
            Assert.DoesNotThrow(
                () => validator.Invoke(null, new object[] { exportRoot }));

            manifestWriter.Invoke(null, new object[] { exportRoot });
            string manifestPath = Path.Combine(
                exportRoot,
                "maaso-avatar-manifest.json");
            string manifestJson = File.ReadAllText(manifestPath);
            Assert.That(manifestJson, Does.Contain("\"streamingAssets\": null"));

            Directory.CreateDirectory(
                Path.Combine(exportRoot, "StreamingAssets"));
            manifestWriter.Invoke(null, new object[] { exportRoot });
            TestWebGLBuildManifest manifest =
                JsonUtility.FromJson<TestWebGLBuildManifest>(
                    File.ReadAllText(manifestPath));

            Assert.That(manifest.schemaVersion, Is.EqualTo(1));
            Assert.That(manifest.buildName, Is.EqualTo("MaasoAvatar"));
            Assert.That(manifest.unityVersion, Is.Not.Empty);
            Assert.That(manifest.productVersion, Is.Not.Null);
            Assert.That(
                manifest.files.loader,
                Is.EqualTo("Build/MaasoAvatar.loader.js"));
            Assert.That(manifest.files.data, Is.EqualTo("Build/MaasoAvatar.data"));
            Assert.That(
                manifest.files.framework,
                Is.EqualTo("Build/MaasoAvatar.framework.js"));
            Assert.That(
                manifest.files.wasm,
                Is.EqualTo("Build/MaasoAvatar.wasm"));
            Assert.That(
                manifest.files.streamingAssets,
                Is.EqualTo("StreamingAssets"));
            foreach (string relativePath in manifest.files.AllPaths())
            {
                Assert.That(Path.IsPathRooted(relativePath), Is.False, relativePath);
                Assert.That(relativePath, Does.Not.Contain(".."));
            }

            File.Delete(Path.Combine(exportRoot, "Build", "MaasoAvatar.wasm"));
            TargetInvocationException missing =
                Assert.Throws<TargetInvocationException>(
                    () => validator.Invoke(null, new object[] { exportRoot }));
            Assert.That(missing.InnerException, Is.TypeOf<InvalidOperationException>());
        }
        finally
        {
            Directory.Delete(exportRoot, true);
        }
    }

    private static Type RequireExporterType()
    {
        Type exporterType = Type.GetType(ExporterTypeName);
        Assert.That(exporterType, Is.Not.Null, ExporterTypeName);
        return exporterType;
    }

    private static void CreateWebGLPlayerFiles(string exportRoot)
    {
        string buildRoot = Path.Combine(exportRoot, "Build");
        Directory.CreateDirectory(buildRoot);
        File.WriteAllText(Path.Combine(exportRoot, "index.html"), string.Empty);
        File.WriteAllBytes(
            Path.Combine(buildRoot, "MaasoAvatar.loader.js"),
            Array.Empty<byte>());
        File.WriteAllBytes(
            Path.Combine(buildRoot, "MaasoAvatar.data"),
            Array.Empty<byte>());
        File.WriteAllBytes(
            Path.Combine(buildRoot, "MaasoAvatar.framework.js"),
            Array.Empty<byte>());
        File.WriteAllBytes(
            Path.Combine(buildRoot, "MaasoAvatar.wasm"),
            Array.Empty<byte>());
    }

    private static string DuplicateBuildPhaseProject()
    {
        return
            "7F4E059F2717216D00A2CBE4 /* GameAssembly */ = {\n" +
            "\tisa = PBXNativeTarget;\n" +
            "\tbuildPhases = (\n" +
            "\t\t7F4E059C2717216D00A2CBE4 /* Sources */,\n" +
            "\t\tC62A2A42F32E085EF849CF0B /* ShellScript */,\n" +
            "\t\tC62A2A42F32E085EF849CF0B /* ShellScript */,\n" +
            "\t);\n" +
            "};\n";
    }

    private static int CountOccurrences(string source, string value)
    {
        int count = 0;
        int startIndex = 0;
        while ((startIndex = source.IndexOf(
                   value,
                   startIndex,
                   StringComparison.Ordinal)) >= 0)
        {
            count += 1;
            startIndex += value.Length;
        }

        return count;
    }

    [Serializable]
    private sealed class TestWebGLBuildManifest
    {
        public int schemaVersion;
        public string buildName;
        public string unityVersion;
        public string productVersion;
        public TestWebGLBuildFiles files;
    }

    [Serializable]
    private sealed class TestWebGLBuildFiles
    {
        public string loader;
        public string data;
        public string framework;
        public string wasm;
        public string streamingAssets;

        public string[] AllPaths()
        {
            return new[] { loader, data, framework, wasm, streamingAssets };
        }
    }
}
