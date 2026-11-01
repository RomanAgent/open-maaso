#if UNITY_EDITOR
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Xml;
using System.Xml.Linq;
using Newtonsoft.Json;
using Formatting = Newtonsoft.Json.Formatting;
using UnityEditor;
using UnityEditor.Build.Reporting;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.SceneManagement;

namespace Maaso.Avatar.Editor
{
    public static class MaasoUnityLibraryExporter
    {
        private const string IOSOutputPath = "Builds/iOS";
        private const string AndroidOutputPath = "Builds/Android";
        private const string WindowsOutputPath = "Builds/Windows/MaasoAvatar.exe";
        private const string MacOSSidecarOutputPath = "Builds/macOS/MaasoAvatar.app";
        private const string MacOSSidecarBundleIdentifier =
            "com.futurpals.maaso.avatar-sidecar";
        private const string WebGLOutputPath = "Builds/WebGL/MaasoAvatar";
        private const string WebGLBuildName = "MaasoAvatar";
        private const string WebGLManifestFileName = "maaso-avatar-manifest.json";
        private const string MacOSPortalSourcePath =
            "Assets/Plugins/macOS/MaasoDesktopAvatarPortalBridge.mm";
        private const string MacOSPortalBundleName =
            "MaasoDesktopAvatarPortalBridge.bundle";
        private const string MacOSPortalGeneratedBundlePath =
            "Assets/Plugins/macOS/GeneratedNative/" + MacOSPortalBundleName;
        private const string MacOSSidecarProtocolFingerprintFileName =
            "maaso-sidecar-protocol.sha256";
        private const string AgentScenePath =
            MaasoDefaultAvatarSceneBuilder.ScenePath;
        private static readonly string[] MacOSSidecarProtocolSourcePaths =
        {
            "lib/src/features/agent/application/avatar/desktop_unity_sidecar_protocol.dart",
            "macos/Runner/MacOSUnityAvatarPortal.swift",
            "unity/masso_avatar/Assets/MaasoAvatar/Scripts/CompanionPortalCaptureController.cs",
            "unity/masso_avatar/Assets/MaasoAvatar/Scripts/DesktopUnitySidecarBridge.cs",
            "unity/masso_avatar/Assets/MaasoAvatar/Scripts/UnityAvatarCommandReceiver.cs",
            "unity/masso_avatar/Assets/Plugins/macOS/MaasoDesktopAvatarPortalBridge.mm",
            "unity/masso_avatar/Assets/MaasoAvatar/Editor/MaasoUnityLibraryExporter.cs",
            "unity/masso_avatar/Assets/Plugins/macOS/MaasoDesktopAvatarPortalBridge.mm.meta"
        };
        private static readonly string[] UnityProjectSettingPaths =
        {
            "ProjectSettings/ProjectSettings.asset"
        };

        [MenuItem("Maaso/Export Unity Library/iOS")]
        public static void ExportIOS()
        {
            Export(BuildTarget.iOS, IOSOutputPath);
        }

        [MenuItem("Maaso/Export Unity Library/Android")]
        public static void ExportAndroid()
        {
            Export(BuildTarget.Android, AndroidOutputPath);
        }

        [MenuItem("Maaso/Export Unity Library/Windows x64")]
        public static void ExportWindows64()
        {
            Export(BuildTarget.StandaloneWindows64, WindowsOutputPath);
        }

        [MenuItem("Maaso/Export Unity Sidecar/macOS")]
        public static void ExportMacOSSidecar()
        {
            Export(BuildTarget.StandaloneOSX, MacOSSidecarOutputPath);
        }

        [MenuItem("Maaso/Export Unity Player/WebGL")]
        public static void ExportWebGL()
        {
            Export(BuildTarget.WebGL, WebGLOutputPath);
        }

        public static void PatchExportedIOSIl2CppHostExecution()
        {
            PatchIOSIl2CppHostExecution(IOSOutputPath);
        }

        private static void Export(BuildTarget target, string outputPath)
        {
            var targetGroup = ResolveTargetGroup(target);
            if (!BuildPipeline.IsBuildTargetSupported(targetGroup, target))
            {
                throw new InvalidOperationException(
                    "Unity build target is unsupported: " + target +
                    ". Install " + ResolveBuildSupportName(target) + " in Unity Hub."
                );
            }

            RefreshActionFbxFolderForBuild();

            var projectSettingBackups = BackupUnityProjectSettingFiles();
            var androidGraphicsApiBackup = target == BuildTarget.Android
                ? AndroidGraphicsApiBackup.Capture()
                : null;
            var scriptingBackendBackup = target == BuildTarget.StandaloneOSX
                ? ScriptingBackendBackup.Capture(BuildTargetGroup.Standalone)
                : null;
            var webGLSettingsBackup = target == BuildTarget.WebGL
                ? WebGLSettingsBackup.Capture()
                : null;
            string productNameBackup = target == BuildTarget.StandaloneOSX ||
                target == BuildTarget.WebGL
                ? PlayerSettings.productName
                : null;
            if (target == BuildTarget.iOS ||
                target == BuildTarget.StandaloneWindows64 ||
                target == BuildTarget.StandaloneOSX ||
                target == BuildTarget.WebGL)
            {
                EditorUserBuildSettings.SwitchActiveBuildTarget(
                    targetGroup,
                    target
                );
            }

            var buildOptions = BuildOptions.None;
            var canAppend = target == BuildTarget.iOS
                && Directory.Exists(outputPath)
                && BuildPipeline.BuildCanBeAppended(target, outputPath) == CanAppendBuild.Yes;

            if (canAppend)
            {
                buildOptions |= BuildOptions.AcceptExternalModificationsToPlayer;
            }
            else
            {
                PrepareCleanOutput(target, outputPath);
            }

            var parent = Path.GetDirectoryName(outputPath);
            if (!string.IsNullOrEmpty(parent))
            {
                Directory.CreateDirectory(parent);
            }

            var previousAndroidProjectExport =
                EditorUserBuildSettings.exportAsGoogleAndroidProject;
            EditorUserBuildSettings.exportAsGoogleAndroidProject = target == BuildTarget.Android;
            var previousScenePath = OpenAgentSceneForBuild(target);

            try
            {
                if (target == BuildTarget.StandaloneOSX)
                {
                    PlayerSettings.productName = "MaasoAvatar";
                    PlayerSettings.SetScriptingBackend(
                        BuildTargetGroup.Standalone,
                        ScriptingImplementation.Mono2x
                    );
                    PrepareMacOSNativePortalPluginForBuild();
                }
                else if (target == BuildTarget.WebGL)
                {
                    PlayerSettings.productName = WebGLBuildName;
                    ConfigureWebGLPlayerSettings();
                }
                ConfigureGraphicsApiForBuild(target);
                CleanupAgentSceneMissingScripts();
                BuildReport report = null;
                RunBuildWithIOSMeshDeformationPolicy(target, outputPath, () =>
                {
                    report = BuildPipeline.BuildPlayer(new BuildPlayerOptions
                    {
                        scenes = ResolveScenes(),
                        locationPathName = outputPath,
                        target = target,
                        options = buildOptions
                    });
                    return report.summary.result;
                });

                if (report.summary.result != BuildResult.Succeeded)
                {
                    throw new InvalidOperationException(
                        "Unity build failed: " + report.summary.result +
                        " (" + report.summary.totalErrors + " errors, " +
                        report.summary.totalWarnings + " warnings)"
                    );
                }

                if (target == BuildTarget.iOS)
                {
                    PatchIOSIl2CppHostExecution(outputPath);
                    // Incremental Unity exports may append the same phase UUID again.
                    // Keep the generated Xcode target graph valid before Flutter links it.
                    SanitizeIOSDuplicateBuildPhases(outputPath);
                }
                else if (target == BuildTarget.StandaloneWindows64)
                {
                    ValidateWindowsPlayerExport(outputPath);
                }
                else if (target == BuildTarget.StandaloneOSX)
                {
                    PatchMacOSSidecarInfoPlist(outputPath);
                    WriteMacOSSidecarProtocolFingerprint(outputPath);
                    SignMacOSSidecar(outputPath);
                    ValidateMacOSSidecarExport(outputPath);
                    VerifyMacOSSidecarSignature(outputPath);
                }
                else if (target == BuildTarget.WebGL)
                {
                    ValidateWebGLPlayerExport(outputPath);
                    WriteWebGLBuildManifest(outputPath);
                }
            }
            finally
            {
                androidGraphicsApiBackup?.Restore();
                scriptingBackendBackup?.Restore();
                webGLSettingsBackup?.Restore();
                if (productNameBackup != null)
                {
                    PlayerSettings.productName = productNameBackup;
                }
                EditorUserBuildSettings.exportAsGoogleAndroidProject =
                    previousAndroidProjectExport;
                RestoreSceneAfterBuild(previousScenePath);
                RestoreUnityProjectSettingFiles(projectSettingBackups);
            }
        }

        /// <summary>
        /// A single-variable iOS compatibility candidate for GPU lockups during
        /// display handoff. Ordinary GPU skinning preserves bones, blendshapes
        /// and authored motion while avoiding the batched compute path. The
        /// device reports do not identify that path as the confirmed cause.
        /// </summary>
        private static BuildResult RunBuildWithIOSMeshDeformationPolicy(
            BuildTarget target, string outputPath, Func<BuildResult> build)
        {
            if (target != BuildTarget.iOS) return build();

            MeshDeformation original = PlayerSettings.meshDeformation;
            var receipt = new IOSMeshDeformationReceipt
            {
                unityVersion = Application.unityVersion,
                startedAtUtc = DateTime.UtcNow.ToString("O"),
                exporterSourceSha256 = BuildPolicyFileSha256(
                    "Assets/MaasoAvatar/Editor/MaasoUnityLibraryExporter.cs"),
                originalMeshDeformation = original.ToString(),
                originalMeshDeformationValue = (int)original
            };
            // This is export evidence, not a runtime asset. It must never enter
            // Data/ or trigger an asset import, model bake or source rewrite.
            string receiptPath = Path.Combine(outputPath, "maaso-ios-rendering-policy.json");
            try
            {
                PlayerSettings.meshDeformation = MeshDeformation.GPU;
                MeshDeformation applied = PlayerSettings.meshDeformation;
                receipt.appliedPreBuildMeshDeformation = applied.ToString();
                receipt.appliedPreBuildMeshDeformationValue = (int)applied;
                if (applied != MeshDeformation.GPU)
                    throw new InvalidOperationException("iOS GPU skinning compatibility policy was not applied.");
                WriteIOSMeshDeformationReceipt(receiptPath, receipt);

                BuildResult result = build();
                receipt.unityBuildResult = result.ToString();
                if (result == BuildResult.Succeeded)
                {
                    string bootConfigPath = Path.Combine(outputPath, "Data", "boot.config");
                    receipt.exportBootConfigSha256 = BuildPolicyFileSha256(bootConfigPath);
                    receipt.exportBuildGuid = File.ReadLines(bootConfigPath)
                        .FirstOrDefault(line => line.StartsWith("build-guid=", StringComparison.Ordinal))
                        ?.Substring("build-guid=".Length);
                    if (string.IsNullOrEmpty(receipt.exportBuildGuid))
                        throw new InvalidDataException("The successful iOS export has no build GUID.");
                }
                return result;
            }
            catch
            {
                receipt.unityBuildResult = "Exception";
                throw;
            }
            finally
            {
                // Restoring only ProjectSettings.asset bytes leaves Unity's
                // in-memory global setting changed for the next platform build.
                PlayerSettings.meshDeformation = original;
                receipt.restoredMeshDeformation = PlayerSettings.meshDeformation.ToString();
                receipt.restoredMeshDeformationValue = (int)PlayerSettings.meshDeformation;
                receipt.originalSettingRestored = PlayerSettings.meshDeformation == original;
                receipt.finishedAtUtc = DateTime.UtcNow.ToString("O");
                WriteIOSMeshDeformationReceipt(receiptPath, receipt);
            }
        }

        private static string BuildPolicyFileSha256(string path)
        {
            using (var algorithm = SHA256.Create())
            using (var stream = File.OpenRead(path))
                return BitConverter.ToString(algorithm.ComputeHash(stream)).Replace("-", "").ToLowerInvariant();
        }

        private static void WriteIOSMeshDeformationReceipt(
            string receiptPath, IOSMeshDeformationReceipt receipt)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(receiptPath));
            File.WriteAllText(receiptPath, JsonConvert.SerializeObject(receipt, Formatting.Indented) + "\n");
        }

        private sealed class IOSMeshDeformationReceipt
        {
            public int schemaVersion = 1;
            public string policy = "ios-unbatched-gpu-compatibility-candidate/v1";
            public bool compatibilityCandidate = true;
            public bool rootCauseConfirmed = false;
            public string target = "iOS";
            public string unityVersion, startedAtUtc, finishedAtUtc;
            public string exporterSourceSha256, exportBootConfigSha256, exportBuildGuid;
            public string requestedMeshDeformation = "GPU";
            public int requestedMeshDeformationValue = (int)MeshDeformation.GPU;
            public string originalMeshDeformation, appliedPreBuildMeshDeformation, restoredMeshDeformation;
            public int originalMeshDeformationValue, appliedPreBuildMeshDeformationValue, restoredMeshDeformationValue;
            public string unityBuildResult = "NotStarted";
            public bool originalSettingRestored;
            public string verificationScope = "Build policy only; post-export validation and physical-device acceptance are separate.";
        }

        private static void PrepareCleanOutput(BuildTarget target, string outputPath)
        {
            if (target == BuildTarget.StandaloneWindows64)
            {
                string outputDirectory = Path.GetDirectoryName(outputPath);
                if (!string.IsNullOrEmpty(outputDirectory) &&
                    Directory.Exists(outputDirectory))
                {
                    Directory.Delete(outputDirectory, true);
                }
                return;
            }

            if (Directory.Exists(outputPath))
            {
                Directory.Delete(outputPath, true);
            }
        }

        private static void ValidateWindowsPlayerExport(string executablePath)
        {
            string outputDirectory = Path.GetDirectoryName(executablePath);
            string playerDataDirectory = Path.Combine(
                outputDirectory ?? string.Empty,
                Path.GetFileNameWithoutExtension(executablePath) + "_Data"
            );
            string unityPlayerPath = Path.Combine(
                outputDirectory ?? string.Empty,
                "UnityPlayer.dll"
            );
            if (!File.Exists(executablePath) ||
                !File.Exists(unityPlayerPath) ||
                !Directory.Exists(playerDataDirectory))
            {
                throw new InvalidOperationException(
                    "Unity Windows player export is incomplete. Expected " +
                    "MaasoAvatar.exe, UnityPlayer.dll, and MaasoAvatar_Data in " +
                    (outputDirectory ?? WindowsOutputPath) + "."
                );
            }

        }

        private static void PatchMacOSSidecarInfoPlist(string appPath)
        {
            var plist = LoadMacOSSidecarInfoPlist(appPath);
            var values = RequireMacOSSidecarPlistValues(plist);
            var dictionary = plist.Root.Element("dict");
            bool changed = false;
            foreach (var replacement in new[]
            {
                new KeyValuePair<string, XElement>("LSUIElement", new XElement("true")),
                new KeyValuePair<string, XElement>(
                    "CFBundleIdentifier", new XElement("string", MacOSSidecarBundleIdentifier))
            })
            {
                if (!values.TryGetValue(replacement.Key, out var existing))
                {
                    dictionary.Add(new XElement("key", replacement.Key), replacement.Value);
                    changed = true;
                }
                else if (!XNode.DeepEquals(existing, replacement.Value))
                {
                    existing.ReplaceWith(replacement.Value);
                    changed = true;
                }
            }

            // A background-only app cannot initialize Unity's normal AppKit/Metal
            // player. Keep its existing principal class, nib and other startup keys.
            if (values.TryGetValue("LSBackgroundOnly", out var backgroundOnly))
            {
                backgroundOnly.ElementsBeforeSelf("key").Last().Remove();
                backgroundOnly.Remove();
                changed = true;
            }
            var documentType = plist.DocumentType;
            if (documentType != null && documentType.InternalSubset != null)
            {
                // XmlReader represents an absent subset as an empty string. Writing
                // that back adds [] to the DTD, which Apple's plist parser rejects.
                documentType.ReplaceWith(new XDocumentType(
                    documentType.Name, documentType.PublicId, documentType.SystemId, null));
                changed = true;
            }
            if (!changed)
            {
                return;
            }

            using (var writer = XmlWriter.Create(
                Path.Combine(appPath, "Contents", "Info.plist"),
                new XmlWriterSettings { Encoding = new UTF8Encoding(false), Indent = false }))
            {
                plist.Save(writer);
            }
            ValidateMacOSSidecarPlistWithApple(appPath);
        }

        private static XDocument LoadMacOSSidecarInfoPlist(string appPath)
        {
            string plistPath = Path.Combine(appPath, "Contents", "Info.plist");
            if (!File.Exists(plistPath))
            {
                throw new InvalidOperationException(
                    "Unity macOS sidecar Info.plist is missing: " + plistPath);
            }
            try
            {
                using (var reader = XmlReader.Create(plistPath, new XmlReaderSettings
                {
                    // Apple's standard external plist DTD is retained, never fetched.
                    XmlResolver = null,
                    DtdProcessing = DtdProcessing.Parse,
                    MaxCharactersFromEntities = 1024,
                    MaxCharactersInDocument = 1024 * 1024
                }))
                {
                    var document = XDocument.Load(reader);
                    if (!string.IsNullOrWhiteSpace(document.DocumentType?.InternalSubset))
                    {
                        throw new InvalidOperationException(
                            "Unity macOS sidecar Info.plist must not declare XML entities.");
                    }
                    return document;
                }
            }
            catch (XmlException exception)
            {
                throw new InvalidOperationException(
                    "Unity macOS sidecar Info.plist is not valid XML: " + plistPath,
                    exception);
            }
        }

        private static Dictionary<string, XElement> RequireMacOSSidecarPlistValues(
            XDocument plist)
        {
            var root = plist.Root;
            if (root == null || root.Name != "plist" ||
                root.Elements().Count() != 1 || root.Element("dict") == null)
            {
                throw new InvalidOperationException(
                    "Unity macOS sidecar Info.plist requires a single root dictionary.");
            }
            var elements = root.Element("dict").Elements().ToArray();
            var values = new Dictionary<string, XElement>(StringComparer.Ordinal);
            for (int index = 0; index < elements.Length; index += 2)
            {
                var key = elements[index];
                if (index + 1 >= elements.Length || key.Name != "key" ||
                    key.HasElements || string.IsNullOrEmpty(key.Value) ||
                    elements[index + 1].Name == "key" || values.ContainsKey(key.Value))
                {
                    throw new InvalidOperationException(
                        "Unity macOS sidecar Info.plist has malformed or duplicate dictionary keys.");
                }
                values.Add(key.Value, elements[index + 1]);
            }
            return values;
        }

        private static void ValidateMacOSSidecarExport(string appPath)
        {
            string executablePath = Path.Combine(
                appPath,
                "Contents",
                "MacOS",
                "MaasoAvatar"
            );
            string dataPath = Path.Combine(
                appPath,
                "Contents",
                "Resources",
                "Data"
            );
            string portalPluginPath = Path.Combine(
                appPath,
                "Contents",
                "PlugIns",
                MacOSPortalBundleName,
                "Contents",
                "MacOS",
                "MaasoDesktopAvatarPortalBridge"
            );
            string protocolFingerprintPath = Path.Combine(
                dataPath,
                MacOSSidecarProtocolFingerprintFileName
            );
            if (!File.Exists(executablePath) ||
                !Directory.Exists(dataPath) ||
                !File.Exists(portalPluginPath) ||
                !File.Exists(protocolFingerprintPath))
            {
                throw new InvalidOperationException(
                    "Unity macOS sidecar export is incomplete. Expected " +
                    "Contents/MacOS/MaasoAvatar, Contents/Resources/Data, and " +
                    "the native Avatar portal plugin and protocol fingerprint in " +
                    appPath + "."
                );
            }
            var plist = LoadMacOSSidecarInfoPlist(appPath);
            var values = RequireMacOSSidecarPlistValues(plist);
            if (!values.TryGetValue("LSUIElement", out var agentPolicy) ||
                agentPolicy.Name != "true" || agentPolicy.HasElements ||
                agentPolicy.HasAttributes || !string.IsNullOrWhiteSpace(agentPolicy.Value) ||
                !values.TryGetValue("CFBundleIdentifier", out var bundleIdentifier) ||
                bundleIdentifier.Name != "string" || bundleIdentifier.HasElements ||
                bundleIdentifier.Value != MacOSSidecarBundleIdentifier ||
                values.ContainsKey("LSBackgroundOnly"))
            {
                throw new InvalidOperationException(
                    "Unity macOS sidecar Info.plist must have LSUIElement=true, " +
                    "CFBundleIdentifier=" + MacOSSidecarBundleIdentifier +
                    ", and no LSBackgroundOnly entry."
                );
            }
            ValidateMacOSSidecarPlistWithApple(appPath);
        }

        private static void ValidateMacOSSidecarPlistWithApple(string appPath)
        {
            if (Application.platform == RuntimePlatform.OSXEditor)
            {
                RunFixedBuildTool(
                    "/usr/bin/plutil",
                    new[] { "-lint", "-s", "--", Path.Combine(appPath, "Contents", "Info.plist") },
                    "Apple's plist parser rejected the Unity macOS sidecar Info.plist.");
            }
        }

        private static void WriteMacOSSidecarProtocolFingerprint(string appPath)
        {
            string dataPath = Path.Combine(
                appPath,
                "Contents",
                "Resources",
                "Data"
            );
            Directory.CreateDirectory(dataPath);
            File.WriteAllText(
                Path.Combine(dataPath, MacOSSidecarProtocolFingerprintFileName),
                ComputeMacOSSidecarProtocolFingerprint() + "\n",
                new UTF8Encoding(false)
            );
        }

        private static string ComputeMacOSSidecarProtocolFingerprint()
        {
            string repositoryRoot = Path.GetFullPath(
                Path.Combine(Application.dataPath, "..", "..", "..")
            );
            byte[] separator = { 0 };
            using (var algorithm = SHA256.Create())
            using (var sink = new CryptoStream(
                Stream.Null,
                algorithm,
                CryptoStreamMode.Write))
            {
                foreach (string relativePath in MacOSSidecarProtocolSourcePaths)
                {
                    string sourcePath = Path.Combine(
                        repositoryRoot,
                        relativePath.Replace('/', Path.DirectorySeparatorChar)
                    );
                    if (!File.Exists(sourcePath))
                    {
                        throw new FileNotFoundException(
                            "macOS sidecar protocol source is missing: " +
                            relativePath,
                            sourcePath
                        );
                    }

                    byte[] pathBytes = Encoding.UTF8.GetBytes(relativePath);
                    sink.Write(pathBytes, 0, pathBytes.Length);
                    sink.Write(separator, 0, separator.Length);
                    using (var source = File.OpenRead(sourcePath))
                    {
                        source.CopyTo(sink);
                    }
                    sink.Write(separator, 0, separator.Length);
                }
                sink.FlushFinalBlock();
                return string.Concat(
                    algorithm.Hash.Select(value => value.ToString("x2"))
                );
            }
        }

        private static void ValidateWebGLPlayerExport(string outputPath)
        {
            var requiredPaths = new[]
            {
                "index.html",
                "Build/" + WebGLBuildName + ".loader.js",
                "Build/" + WebGLBuildName + ".data",
                "Build/" + WebGLBuildName + ".framework.js",
                "Build/" + WebGLBuildName + ".wasm",
            };
            var missingPaths = requiredPaths
                .Where(relativePath => !File.Exists(
                    ToSystemPath(outputPath, relativePath)))
                .ToArray();
            if (missingPaths.Length == 0)
            {
                return;
            }

            throw new InvalidOperationException(
                "Unity WebGL player export is incomplete. Missing: " +
                string.Join(", ", missingPaths) + "."
            );
        }

        private static void WriteWebGLBuildManifest(string outputPath)
        {
            var manifest = new WebGLBuildManifest
            {
                schemaVersion = 1,
                buildName = WebGLBuildName,
                unityVersion = Application.unityVersion,
                productVersion = PlayerSettings.bundleVersion,
                files = new WebGLBuildFiles
                {
                    loader = "Build/" + WebGLBuildName + ".loader.js",
                    data = "Build/" + WebGLBuildName + ".data",
                    framework = "Build/" + WebGLBuildName + ".framework.js",
                    wasm = "Build/" + WebGLBuildName + ".wasm",
                    streamingAssets = Directory.Exists(
                        Path.Combine(outputPath, "StreamingAssets"))
                        ? "StreamingAssets"
                        : null,
                },
            };
            File.WriteAllText(
                Path.Combine(outputPath, WebGLManifestFileName),
                JsonConvert.SerializeObject(manifest, Formatting.Indented)
            );
        }

        private static string ToSystemPath(string rootPath, string relativeWebPath)
        {
            return Path.Combine(
                new[] { rootPath }
                    .Concat(relativeWebPath.Split('/'))
                    .ToArray()
            );
        }

        private static void PrepareMacOSNativePortalPluginForBuild()
        {
            // BuildPlayer must see the native importer, so Unity records startup
            // preloading instead of first loading this plugin at a C# DllImport.
            BuildMacOSNativePortalPlugin(MacOSPortalGeneratedBundlePath);
            AssetDatabase.ImportAsset(
                MacOSPortalGeneratedBundlePath,
                ImportAssetOptions.ForceSynchronousImport | ImportAssetOptions.ForceUpdate);
            var importer = AssetImporter.GetAtPath(MacOSPortalGeneratedBundlePath) as PluginImporter;
            ConfigureMacOSNativePortalPluginImporter(importer);
            importer.SaveAndReimport();
            ValidateMacOSNativePortalPluginImporter(
                AssetImporter.GetAtPath(MacOSPortalGeneratedBundlePath) as PluginImporter);

            var sourceImporter = AssetImporter.GetAtPath(MacOSPortalSourcePath) as PluginImporter;
            if (sourceImporter == null || sourceImporter.GetCompatibleWithAnyPlatform() ||
                sourceImporter.GetCompatibleWithEditor() ||
                sourceImporter.GetCompatibleWithPlatform(BuildTarget.StandaloneOSX))
            {
                throw new InvalidOperationException(
                    "The macOS portal .mm source must be disabled as a Unity plugin; " +
                    "only the generated native bundle is a Player input.");
            }
        }

        private static void ConfigureMacOSNativePortalPluginImporter(PluginImporter importer)
        {
            if (importer == null || !importer.isNativePlugin)
            {
                throw new InvalidOperationException("The macOS portal requires a native PluginImporter.");
            }
            importer.ClearSettings();
            importer.SetCompatibleWithAnyPlatform(false);
            importer.SetCompatibleWithEditor(false);
            importer.SetCompatibleWithPlatform(BuildTarget.StandaloneOSX, true);
            importer.SetPlatformData(BuildTarget.StandaloneOSX, "CPU", "AnyCPU");
            importer.isPreloaded = true;
        }

        private static void ValidateMacOSNativePortalPluginImporter(PluginImporter importer)
        {
            if (importer == null || !importer.isNativePlugin || !importer.isPreloaded ||
                importer.GetCompatibleWithAnyPlatform() || importer.GetCompatibleWithEditor() ||
                !importer.GetCompatibleWithPlatform(BuildTarget.StandaloneOSX) ||
                importer.GetPlatformData(BuildTarget.StandaloneOSX, "CPU") != "AnyCPU" ||
                new[] { BuildTarget.iOS, BuildTarget.Android, BuildTarget.WebGL,
                    BuildTarget.StandaloneWindows64, BuildTarget.StandaloneLinux64 }
                    .Any(importer.GetCompatibleWithPlatform))
            {
                throw new InvalidOperationException(
                    "The generated macOS portal bundle must preload only in the macOS Player.");
            }
        }

        private static void BuildMacOSNativePortalPlugin(string bundlePath)
        {
            string sourcePath = Path.GetFullPath(MacOSPortalSourcePath);
            string pluginApiPath = Path.Combine(
                EditorApplication.applicationContentsPath,
                "Resources",
                "PluginAPI"
            );
            if (!File.Exists(sourcePath) ||
                !File.Exists(Path.Combine(pluginApiPath, "IUnityGraphics.h")))
            {
                throw new FileNotFoundException(
                    "macOS Avatar portal source or Unity PluginAPI headers are missing."
                );
            }

            string bundleContentsPath = Path.Combine(bundlePath, "Contents");
            string bundleExecutablePath = Path.Combine(
                bundleContentsPath,
                "MacOS",
                "MaasoDesktopAvatarPortalBridge"
            );
            if (Directory.Exists(bundlePath))
            {
                Directory.Delete(bundlePath, true);
            }
            Directory.CreateDirectory(Path.GetDirectoryName(bundleExecutablePath));
            File.WriteAllText(
                Path.Combine(bundleContentsPath, "Info.plist"),
                MacOSPortalBundleInfoPlist()
            );

            RunFixedBuildTool(
                "/usr/bin/xcrun",
                new[]
                {
                    "--sdk", "macosx", "clang++",
                    "-std=c++17",
                    "-fobjc-arc",
                    "-fvisibility=hidden",
                    "-bundle",
                    "-arch", "arm64",
                    "-arch", "x86_64",
                    "-mmacosx-version-min=14.0",
                    "-I", pluginApiPath,
                    "-framework", "AppKit",
                    "-framework", "Foundation",
                    "-framework", "CoreVideo",
                    "-framework", "IOSurface",
                    "-framework", "Metal",
                    sourcePath,
                    "-o", bundleExecutablePath,
                },
                "Failed to compile the macOS Avatar portal native bundle."
            );
            RunFixedBuildTool(
                "/usr/bin/codesign",
                new[] { "--force", "--sign", "-", bundlePath },
                "Failed to sign the macOS Avatar portal native bundle."
            );
        }

        private static void SignMacOSSidecar(string appPath)
        {
            RunFixedBuildTool(
                "/usr/bin/codesign",
                new[] { "--force", "--deep", "--sign", "-", appPath },
                "Failed to re-sign the macOS Unity sidecar."
            );
        }

        private static void VerifyMacOSSidecarSignature(string appPath)
        {
            RunFixedBuildTool(
                "/usr/bin/codesign",
                new[] { "--verify", "--deep", "--strict", appPath },
                "The macOS Unity sidecar signature is invalid."
            );
        }

        private static void RunFixedBuildTool(
            string executable,
            IReadOnlyList<string> arguments,
            string failureMessage)
        {
            var startInfo = new System.Diagnostics.ProcessStartInfo
            {
                FileName = executable,
                Arguments = string.Join(" ", arguments.Select(QuoteProcessArgument)),
                UseShellExecute = false,
                CreateNoWindow = true,
            };
            using (var process = System.Diagnostics.Process.Start(startInfo))
            {
                if (process == null)
                {
                    throw new InvalidOperationException(failureMessage);
                }
                process.WaitForExit();
                if (process.ExitCode != 0)
                {
                    throw new InvalidOperationException(
                        failureMessage + " Exit code: " + process.ExitCode + "."
                    );
                }
            }
        }

        private static string QuoteProcessArgument(string value)
        {
            if (string.IsNullOrEmpty(value) || value.Any(char.IsControl))
            {
                throw new InvalidOperationException(
                    "A fixed macOS build-tool argument is invalid."
                );
            }
            return "\"" + value.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"";
        }

        private static string MacOSPortalBundleInfoPlist()
        {
            return
                "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" +
                "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" " +
                "\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n" +
                "<plist version=\"1.0\"><dict>\n" +
                "<key>CFBundleExecutable</key>" +
                "<string>MaasoDesktopAvatarPortalBridge</string>\n" +
                "<key>CFBundleIdentifier</key>" +
                "<string>com.futurpals.maaso.avatar-portal</string>\n" +
                "<key>CFBundlePackageType</key><string>BNDL</string>\n" +
                "<key>CFBundleVersion</key><string>1</string>\n" +
                "</dict></plist>\n";
        }

        private static void ConfigureGraphicsApiForBuild(BuildTarget target)
        {
            if (target != BuildTarget.Android)
            {
                return;
            }

            PlayerSettings.SetUseDefaultGraphicsAPIs(BuildTarget.Android, false);
            PlayerSettings.SetGraphicsAPIs(
                BuildTarget.Android,
                new[] { GraphicsDeviceType.OpenGLES3 }
            );
        }

        private static void ConfigureWebGLPlayerSettings()
        {
            PlayerSettings.preserveFramebufferAlpha = true;
            PlayerSettings.WebGL.compressionFormat = WebGLCompressionFormat.Disabled;
            PlayerSettings.WebGL.decompressionFallback = false;
            PlayerSettings.WebGL.threadsSupport = false;
            PlayerSettings.WebGL.nameFilesAsHashes = false;
            PlayerSettings.WebGL.dataCaching = true;
        }

        private static void PatchIOSIl2CppHostExecution(string outputPath)
        {
            var projectPath = Path.Combine(
                outputPath,
                "Unity-iPhone.xcodeproj/project.pbxproj"
            );
            if (!File.Exists(projectPath))
            {
                throw new FileNotFoundException(
                    "Unity iOS Xcode project not found: " + projectPath
                );
            }

            var project = File.ReadAllText(projectPath);
            const string originalHostSetup =
                "IL2CPP_DIR=\\\"$PROJECT_DIR/Il2CppOutputProject/IL2CPP/build/deploy_$HOST_ARCH\\\"\\n" +
                "IL2CPP=\\\"$IL2CPP_DIR/il2cpp\\\"";
            const string legacyPolicySafeHostSetup =
                "IL2CPP_SOURCE_ROOT=\\\"$PROJECT_DIR/Il2CppOutputProject/IL2CPP\\\"\\n" +
                "MAASO_IL2CPP_CACHE_ROOT=\\\"/private/tmp/maaso-unity-il2cpp-${USER:-developer}\\\"\\n" +
                "IL2CPP_SOURCE_FINGERPRINT=$(/usr/bin/shasum -a 256 " +
                "\\\"$IL2CPP_SOURCE_ROOT/BeeLocalCacheTool\\\" " +
                "\\\"$IL2CPP_SOURCE_ROOT/build/deploy_$HOST_ARCH/il2cpp\\\" " +
                "\\\"$IL2CPP_SOURCE_ROOT/build/deploy_$HOST_ARCH/libhostfxr.dylib\\\" " +
                "| /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')\\n" +
                "IL2CPP_ROOT=\\\"$MAASO_IL2CPP_CACHE_ROOT/$IL2CPP_SOURCE_FINGERPRINT/IL2CPP\\\"\\n" +
                "if [ ! -x \\\"$IL2CPP_ROOT/build/deploy_$HOST_ARCH/il2cpp\\\" ]; then\\n" +
                "    mkdir -p \\\"$(dirname \\\"$IL2CPP_ROOT\\\")\\\"\\n" +
                "    /usr/bin/ditto \\\"$IL2CPP_SOURCE_ROOT\\\" \\\"$IL2CPP_ROOT\\\"\\n" +
                "fi\\n" +
                "export REAPI_CACHE_CLIENT=\\\"$IL2CPP_ROOT/BeeLocalCacheTool\\\"\\n" +
                "IL2CPP_DIR=\\\"$IL2CPP_ROOT/build/deploy_$HOST_ARCH\\\"\\n" +
                "IL2CPP=\\\"$IL2CPP_DIR/il2cpp\\\"";
            const string policySafeHostSetup =
                "IL2CPP_SOURCE_ROOT=\\\"$PROJECT_DIR/Il2CppOutputProject/IL2CPP\\\"\\n" +
                "MAASO_IL2CPP_CACHE_ROOT=\\\"/private/tmp/maaso-unity-il2cpp-${USER:-developer}\\\"\\n" +
                "MAASO_IL2CPP_CACHE_SCHEMA=\\\"2\\\"\\n" +
                "IL2CPP_DEPLOY_ROOT=\\\"$IL2CPP_SOURCE_ROOT/build/deploy_$HOST_ARCH\\\"\\n" +
                "if [ ! -x \\\"$IL2CPP_DEPLOY_ROOT/il2cpp\\\" ] || " +
                "[ ! -f \\\"$IL2CPP_DEPLOY_ROOT/il2cpp.deps.json\\\" ] || " +
                "[ ! -f \\\"$IL2CPP_DEPLOY_ROOT/System.IO.Pipelines.dll\\\" ]; then\\n" +
                "    echo \\\"error: Unity IL2CPP source dependencies are incomplete.\\\" >&2\\n" +
                "    exit 1\\n" +
                "fi\\n" +
                "IL2CPP_SOURCE_FINGERPRINT=$(/usr/bin/shasum -a 256 " +
                "\\\"$IL2CPP_SOURCE_ROOT/BeeLocalCacheTool\\\" " +
                "\\\"$IL2CPP_DEPLOY_ROOT/il2cpp\\\" " +
                "\\\"$IL2CPP_DEPLOY_ROOT/il2cpp.deps.json\\\" " +
                "\\\"$IL2CPP_DEPLOY_ROOT/libhostfxr.dylib\\\" " +
                "\\\"$IL2CPP_DEPLOY_ROOT/System.Text.Json.dll\\\" " +
                "\\\"$IL2CPP_DEPLOY_ROOT/System.IO.Pipelines.dll\\\" " +
                "| /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')\\n" +
                "IL2CPP_CACHE_ENTRY=\\\"$MAASO_IL2CPP_CACHE_ROOT/" +
                "$MAASO_IL2CPP_CACHE_SCHEMA-$IL2CPP_SOURCE_FINGERPRINT\\\"\\n" +
                "IL2CPP_ROOT=\\\"$IL2CPP_CACHE_ENTRY/IL2CPP\\\"\\n" +
                "IL2CPP_CACHE_READY=\\\"$IL2CPP_CACHE_ENTRY/.complete\\\"\\n" +
                "if [ ! -f \\\"$IL2CPP_CACHE_READY\\\" ] || " +
                "[ ! -x \\\"$IL2CPP_ROOT/build/deploy_$HOST_ARCH/il2cpp\\\" ] || " +
                "[ ! -f \\\"$IL2CPP_ROOT/build/deploy_$HOST_ARCH/System.IO.Pipelines.dll\\\" ]; then\\n" +
                "    mkdir -p \\\"$(dirname \\\"$IL2CPP_ROOT\\\")\\\"\\n" +
                "    /usr/bin/ditto \\\"$IL2CPP_SOURCE_ROOT\\\" \\\"$IL2CPP_ROOT\\\"\\n" +
                "    if [ ! -x \\\"$IL2CPP_ROOT/build/deploy_$HOST_ARCH/il2cpp\\\" ] || " +
                "[ ! -f \\\"$IL2CPP_ROOT/build/deploy_$HOST_ARCH/System.IO.Pipelines.dll\\\" ]; then\\n" +
                "        echo \\\"error: Unity IL2CPP cache copy is incomplete.\\\" >&2\\n" +
                "        exit 1\\n" +
                "    fi\\n" +
                "    /usr/bin/touch \\\"$IL2CPP_CACHE_READY\\\"\\n" +
                "fi\\n" +
                "export REAPI_CACHE_CLIENT=\\\"$IL2CPP_ROOT/BeeLocalCacheTool\\\"\\n" +
                "IL2CPP_DIR=\\\"$IL2CPP_ROOT/build/deploy_$HOST_ARCH\\\"\\n" +
                "IL2CPP=\\\"$IL2CPP_DIR/il2cpp\\\"";
            const string originalCustomRoot =
                "--custom-il2-cpp-root=\\\"Il2CppOutputProject/IL2CPP\\\"";
            const string policySafeCustomRoot =
                "--custom-il2-cpp-root=\\\"$IL2CPP_ROOT\\\"";

            if (project.Contains("MAASO_IL2CPP_CACHE_SCHEMA=\\\"2\\\""))
            {
                return;
            }

            if (project.Contains("MAASO_IL2CPP_CACHE_ROOT"))
            {
                if (!project.Contains(legacyPolicySafeHostSetup))
                {
                    throw new InvalidOperationException(
                        "Unity iOS IL2CPP cache patch format changed; " +
                        "cannot upgrade the policy-safe host cache."
                    );
                }

                project = project.Replace(
                    legacyPolicySafeHostSetup,
                    policySafeHostSetup
                );
            }
            else
            {
                if (!project.Contains(originalHostSetup) ||
                    !project.Contains(originalCustomRoot))
                {
                    throw new InvalidOperationException(
                        "Unity iOS IL2CPP build phase format changed; " +
                        "cannot install the policy-safe host cache."
                    );
                }

                project = project.Replace(originalHostSetup, policySafeHostSetup);
                project = project.Replace(originalCustomRoot, policySafeCustomRoot);
            }

            File.WriteAllText(projectPath, project);
            Debug.Log(
                "[MaasoAvatar] Patched iOS IL2CPP host execution to use " +
                "a policy-safe temporary cache."
            );
        }

        private static int SanitizeIOSDuplicateBuildPhases(string outputPath)
        {
            var projectPath = Path.Combine(
                outputPath,
                "Unity-iPhone.xcodeproj/project.pbxproj"
            );
            if (!File.Exists(projectPath))
            {
                throw new FileNotFoundException(
                    "Unity iOS Xcode project not found: " + projectPath
                );
            }

            var sourceLines = File.ReadAllLines(projectPath);
            var sanitizedLines = new List<string>(sourceLines.Length);
            HashSet<string> phaseReferences = null;
            var removedCount = 0;

            foreach (var line in sourceLines)
            {
                var trimmedLine = line.Trim();
                if (trimmedLine == "buildPhases = (")
                {
                    phaseReferences = new HashSet<string>(StringComparer.Ordinal);
                    sanitizedLines.Add(line);
                    continue;
                }

                if (phaseReferences != null && trimmedLine == ");")
                {
                    phaseReferences = null;
                    sanitizedLines.Add(line);
                    continue;
                }

                var reference = phaseReferences == null
                    ? null
                    : IOSBuildPhaseReference(trimmedLine);
                if (reference != null && !phaseReferences.Add(reference))
                {
                    removedCount += 1;
                    continue;
                }

                sanitizedLines.Add(line);
            }

            if (removedCount == 0)
            {
                return 0;
            }

            File.WriteAllLines(projectPath, sanitizedLines);
            Debug.Log(
                "[MaasoAvatar] Removed " + removedCount +
                " duplicate iOS Xcode build phase reference(s)."
            );
            return removedCount;
        }

        private static string IOSBuildPhaseReference(string trimmedLine)
        {
            if (!trimmedLine.EndsWith(",", StringComparison.Ordinal))
            {
                return null;
            }

            var commentIndex = trimmedLine.IndexOf(
                " /*",
                StringComparison.Ordinal
            );
            if (commentIndex <= 0)
            {
                return null;
            }

            var identifier = trimmedLine.Substring(0, commentIndex);
            return identifier.Length == 24 && identifier.All(Uri.IsHexDigit)
                ? identifier
                : null;
        }

        [MenuItem("Maaso/Tools/Cleanup Agent Scene Missing Scripts")]
        public static void CleanupAgentSceneMissingScripts()
        {
            if (AssetDatabase.LoadAssetAtPath<SceneAsset>(AgentScenePath) == null)
            {
                throw new FileNotFoundException(
                    "Agent Unity scene not found: " + AgentScenePath
                );
            }

            var scene = SceneManager.GetActiveScene();
            if (scene.path != AgentScenePath)
            {
                scene = EditorSceneManager.OpenScene(AgentScenePath, OpenSceneMode.Single);
            }

            var removedCount = 0;
            var roots = scene.GetRootGameObjects();
            foreach (var root in roots)
            {
                var transforms = root.GetComponentsInChildren<Transform>(true);
                foreach (var transform in transforms)
                {
                    removedCount +=
                        GameObjectUtility.RemoveMonoBehavioursWithMissingScript(
                            transform.gameObject
                        );
                }
            }

            if (removedCount == 0)
            {
                return;
            }

            EditorSceneManager.MarkSceneDirty(scene);
            EditorSceneManager.SaveScene(scene);
            Debug.Log(
                "[MaasoAvatar] Removed " + removedCount +
                " missing script reference(s) from " + AgentScenePath
            );
        }

        private static void RefreshActionFbxFolderForBuild()
        {
            if (!MaasoHumanoidActionImporter.TryResolveDefaultSourceFolder(
                    out var sourceFolder
                ))
            {
                Debug.Log(
                    "[MaasoAvatar] " +
                    MaasoHumanoidActionImporter.ExternalActionFolderEnv +
                    " is not set; using checked-in action assets."
                );
                return;
            }

            if (!Directory.Exists(sourceFolder))
            {
                Debug.LogWarning(
                    "[MaasoAvatar] Configured action FBX folder not found; " +
                    "using checked-in action assets: " + sourceFolder
                );
                return;
            }

            try
            {
                MaasoHumanoidActionImporter.ImportActionFbxFolder(sourceFolder);
            }
            catch (IOException)
            {
                // APFS/external folders can surface EINTR while Unity is
                // enumerating a large action directory. Retry once so a
                // transient filesystem interruption does not invalidate an
                // otherwise reproducible mobile export.
                System.Threading.Thread.Sleep(150);
                MaasoHumanoidActionImporter.ImportActionFbxFolder(sourceFolder);
            }
        }

        private static List<ProjectSettingBackup> BackupUnityProjectSettingFiles()
        {
            var backups = new List<ProjectSettingBackup>();
            foreach (var settingPath in UnityProjectSettingPaths)
            {
                if (!File.Exists(settingPath))
                {
                    continue;
                }

                backups.Add(new ProjectSettingBackup(
                    settingPath,
                    File.ReadAllBytes(settingPath)
                ));
            }

            return backups;
        }

        private static void RestoreUnityProjectSettingFiles(
            List<ProjectSettingBackup> backups
        )
        {
            foreach (var backup in backups)
            {
                File.WriteAllBytes(backup.Path, backup.SerializedBytes);
            }
        }

        private static string OpenAgentSceneForBuild(BuildTarget target)
        {
            if (target != BuildTarget.iOS)
            {
                return null;
            }

            if (AssetDatabase.LoadAssetAtPath<SceneAsset>(AgentScenePath) == null)
            {
                throw new FileNotFoundException(
                    "Agent Unity scene not found: " + AgentScenePath
                );
            }

            var activeScene = SceneManager.GetActiveScene();
            var previousScenePath = activeScene.path;
            if (previousScenePath == AgentScenePath)
            {
                return null;
            }

            if (!Application.isBatchMode &&
                !EditorSceneManager.SaveCurrentModifiedScenesIfUserWantsTo())
            {
                throw new OperationCanceledException(
                    "Unity Library export cancelled while saving modified scenes."
                );
            }

            EditorSceneManager.OpenScene(AgentScenePath, OpenSceneMode.Single);
            Debug.Log("[MaasoAvatar] Opened agent scene before iOS export: " + AgentScenePath);
            return previousScenePath;
        }

        private static void RestoreSceneAfterBuild(string previousScenePath)
        {
            if (string.IsNullOrEmpty(previousScenePath) ||
                previousScenePath == AgentScenePath ||
                AssetDatabase.LoadAssetAtPath<SceneAsset>(previousScenePath) == null)
            {
                return;
            }

            EditorSceneManager.OpenScene(previousScenePath, OpenSceneMode.Single);
        }

        private static string[] ResolveScenes()
        {
            // The single personal room is a Resources prefab. No additional map
            // scenes enter a package through editor build settings.
            return new[] { AgentScenePath };
        }

        private static BuildTargetGroup ResolveTargetGroup(BuildTarget target)
        {
            switch (target)
            {
                case BuildTarget.iOS:
                    return BuildTargetGroup.iOS;
                case BuildTarget.Android:
                    return BuildTargetGroup.Android;
                case BuildTarget.StandaloneWindows64:
                case BuildTarget.StandaloneOSX:
                    return BuildTargetGroup.Standalone;
                case BuildTarget.WebGL:
                    return BuildTargetGroup.WebGL;
                default:
                    return BuildTargetGroup.Unknown;
            }
        }

        private static string ResolveBuildSupportName(BuildTarget target)
        {
            switch (target)
            {
                case BuildTarget.iOS:
                    return "iOS Build Support";
                case BuildTarget.Android:
                    return "Android Build Support";
                case BuildTarget.StandaloneWindows64:
                    return "Windows Build Support (Mono)";
                case BuildTarget.StandaloneOSX:
                    return "Mac Build Support (Mono/IL2CPP)";
                case BuildTarget.WebGL:
                    return "WebGL Build Support";
                default:
                    return target + " Build Support";
            }
        }

        private sealed class ProjectSettingBackup
        {
            public readonly string Path;
            public readonly byte[] SerializedBytes;

            public ProjectSettingBackup(string path, byte[] serializedBytes)
            {
                Path = path;
                SerializedBytes = serializedBytes;
            }
        }

        private sealed class AndroidGraphicsApiBackup
        {
            private readonly bool useDefaultGraphicsApis;
            private readonly GraphicsDeviceType[] graphicsApis;

            private AndroidGraphicsApiBackup(
                bool useDefaultGraphicsApis,
                GraphicsDeviceType[] graphicsApis
            )
            {
                this.useDefaultGraphicsApis = useDefaultGraphicsApis;
                this.graphicsApis = graphicsApis;
            }

            public static AndroidGraphicsApiBackup Capture()
            {
                return new AndroidGraphicsApiBackup(
                    PlayerSettings.GetUseDefaultGraphicsAPIs(BuildTarget.Android),
                    PlayerSettings.GetGraphicsAPIs(BuildTarget.Android)
                );
            }

            public void Restore()
            {
                PlayerSettings.SetGraphicsAPIs(BuildTarget.Android, graphicsApis);
                PlayerSettings.SetUseDefaultGraphicsAPIs(
                    BuildTarget.Android,
                    useDefaultGraphicsApis
                );
            }
        }

        private sealed class ScriptingBackendBackup
        {
            private readonly BuildTargetGroup targetGroup;
            private readonly ScriptingImplementation implementation;

            private ScriptingBackendBackup(
                BuildTargetGroup targetGroup,
                ScriptingImplementation implementation)
            {
                this.targetGroup = targetGroup;
                this.implementation = implementation;
            }

            public static ScriptingBackendBackup Capture(BuildTargetGroup targetGroup)
            {
                return new ScriptingBackendBackup(
                    targetGroup,
                    PlayerSettings.GetScriptingBackend(targetGroup)
                );
            }

            public void Restore()
            {
                PlayerSettings.SetScriptingBackend(targetGroup, implementation);
            }
        }

        private sealed class WebGLSettingsBackup
        {
            private readonly WebGLCompressionFormat compressionFormat;
            private readonly bool decompressionFallback;
            private readonly bool threadsSupport;
            private readonly bool nameFilesAsHashes;
            private readonly bool dataCaching;
            private readonly bool preserveFramebufferAlpha;

            private WebGLSettingsBackup(
                WebGLCompressionFormat compressionFormat,
                bool decompressionFallback,
                bool threadsSupport,
                bool nameFilesAsHashes,
                bool dataCaching,
                bool preserveFramebufferAlpha)
            {
                this.compressionFormat = compressionFormat;
                this.decompressionFallback = decompressionFallback;
                this.threadsSupport = threadsSupport;
                this.nameFilesAsHashes = nameFilesAsHashes;
                this.dataCaching = dataCaching;
                this.preserveFramebufferAlpha = preserveFramebufferAlpha;
            }

            public static WebGLSettingsBackup Capture()
            {
                return new WebGLSettingsBackup(
                    PlayerSettings.WebGL.compressionFormat,
                    PlayerSettings.WebGL.decompressionFallback,
                    PlayerSettings.WebGL.threadsSupport,
                    PlayerSettings.WebGL.nameFilesAsHashes,
                    PlayerSettings.WebGL.dataCaching,
                    PlayerSettings.preserveFramebufferAlpha
                );
            }

            public void Restore()
            {
                PlayerSettings.WebGL.compressionFormat = compressionFormat;
                PlayerSettings.WebGL.decompressionFallback =
                    decompressionFallback;
                PlayerSettings.WebGL.threadsSupport = threadsSupport;
                PlayerSettings.WebGL.nameFilesAsHashes = nameFilesAsHashes;
                PlayerSettings.WebGL.dataCaching = dataCaching;
                PlayerSettings.preserveFramebufferAlpha =
                    preserveFramebufferAlpha;
            }
        }

        private sealed class WebGLBuildManifest
        {
            public int schemaVersion;
            public string buildName;
            public string unityVersion;
            public string productVersion;
            public WebGLBuildFiles files;
        }

        private sealed class WebGLBuildFiles
        {
            public string loader;
            public string data;
            public string framework;
            public string wasm;
            public string streamingAssets;
        }

    }
}
#endif
