#if UNITY_EDITOR
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using UniVRM10;
using UnityEditor;
using UnityEngine;

namespace Maaso.Avatar.Editor
{
    public static class MaasoVrmSmokeTester
    {
        private const string ControllerPath =
            "Assets/MaasoAvatar/Animations/Humanoid/MaasoHumanoid.controller";

        public static void RunFromCommandLine()
        {
            string modelPath = RequiredArgument("-maasoVrmPath");
            string screenshotPath = RequiredArgument("-maasoVrmScreenshot");
            string reportPath = RequiredArgument("-maasoVrmReport");
            float expectedHeightMeters = OptionalFloatArgument(
                "-maasoExpectedHeight",
                0f);
            if (!File.Exists(modelPath))
            {
                throw new FileNotFoundException("VRM smoke model not found.", modelPath);
            }

            Vrm10Instance instance = null;
            GameObject cameraObject = null;
            GameObject keyLightObject = null;
            GameObject fillLightObject = null;
            try
            {
                instance = MaasoVrmLoader.LoadVrm10Async(modelPath)
                    .GetAwaiter()
                    .GetResult();
                if (instance == null)
                {
                    throw new InvalidOperationException("UniVRM returned no model instance.");
                }

                Animator animator = instance.GetComponentInChildren<Animator>(true);
                if (animator == null || animator.avatar == null ||
                    !animator.avatar.isHuman || !animator.avatar.isValid)
                {
                    throw new InvalidOperationException(
                        "Imported VRM does not expose a valid Humanoid avatar.");
                }

                Renderer[] renderers = instance.GetComponentsInChildren<Renderer>(true)
                    .Where(renderer => renderer != null && renderer.enabled)
                    .ToArray();
                if (renderers.Length == 0)
                {
                    throw new InvalidOperationException("Imported VRM has no visible renderer.");
                }
                Bounds conservativeLoadedBounds = ConservativeRenderBounds(renderers);
                Bounds loadedBounds = RenderBounds(renderers);
                float loadedBoneScaleDeviation = MaxHumanoidBoneScaleDeviation(animator);
                float loadedHumanScale = animator.humanScale;

                RuntimeAnimatorController controller =
                    AssetDatabase.LoadAssetAtPath<RuntimeAnimatorController>(ControllerPath);
                if (controller == null)
                {
                    throw new InvalidOperationException(
                        "Maaso Humanoid controller is missing.");
                }
                animator.runtimeAnimatorController = controller;
                animator.applyRootMotion = false;
                animator.Rebind();
                animator.Update(0f);
                Bounds reboundBounds = RenderBounds(renderers);
                float reboundBoneScaleDeviation = MaxHumanoidBoneScaleDeviation(animator);
                float reboundHumanScale = animator.humanScale;

                Vrm10RuntimeExpression expression = instance.Runtime.Expression;
                ExpressionKey[] requiredExpressions =
                {
                    ExpressionKey.Aa,
                    ExpressionKey.Blink,
                    ExpressionKey.Happy,
                    ExpressionKey.Sad,
                    ExpressionKey.Angry,
                    ExpressionKey.Surprised,
                    ExpressionKey.Relaxed,
                };
                ExpressionKey[] missingExpressions = requiredExpressions
                    .Where(required => !expression.ExpressionKeys.Any(
                        available => available.Equals(required)))
                    .ToArray();
                if (missingExpressions.Length > 0)
                {
                    throw new InvalidOperationException(
                        "VRM is missing Maaso expressions: " +
                        string.Join(", ", missingExpressions.Select(value => value.ToString())));
                }
                expression.SetWeight(ExpressionKey.Happy, 0.72f);
                expression.SetWeight(ExpressionKey.Aa, 0.18f);
                instance.Runtime.Process();
                Bounds bounds = RenderBounds(renderers);
                float expressionBoneScaleDeviation = MaxHumanoidBoneScaleDeviation(animator);
                float rebindHeightRatio = reboundBounds.size.y / loadedBounds.size.y;
                float expressionHeightRatio = bounds.size.y / reboundBounds.size.y;
                float expectedHeightRatio = expectedHeightMeters > 0f
                    ? loadedBounds.size.y / expectedHeightMeters
                    : 1f;
                var validationErrors = new List<string>();
                if (bounds.size.y < 0.5f || bounds.size.y > 4f)
                {
                    validationErrors.Add(
                        $"Imported VRM height is unsupported: {bounds.size.y:F3}m.");
                }
                if (expectedHeightMeters > 0f &&
                    (expectedHeightRatio < 0.95f || expectedHeightRatio > 1.05f))
                {
                    validationErrors.Add(
                        $"Loaded height differs from the authored height: " +
                        $"{loadedBounds.size.y:F3}m vs {expectedHeightMeters:F3}m " +
                        $"({expectedHeightRatio:F3}x).");
                }
                if (rebindHeightRatio < 0.95f || rebindHeightRatio > 1.05f)
                {
                    validationErrors.Add(
                        $"Animator Rebind changed renderer height by " +
                        $"{rebindHeightRatio:F3}x.");
                }
                if (expressionHeightRatio < 0.98f || expressionHeightRatio > 1.02f)
                {
                    validationErrors.Add(
                        $"Expression sampling changed renderer height by " +
                        $"{expressionHeightRatio:F3}x.");
                }
                if (loadedBoneScaleDeviation > 0.05f ||
                    reboundBoneScaleDeviation > 0.05f ||
                    expressionBoneScaleDeviation > 0.05f)
                {
                    validationErrors.Add(
                        $"Humanoid bone localScale deviates from one by up to " +
                        $"{Mathf.Max(loadedBoneScaleDeviation, Mathf.Max(reboundBoneScaleDeviation, expressionBoneScaleDeviation)):F4}.");
                }

                instance.transform.position += new Vector3(
                    -bounds.center.x,
                    -bounds.min.y,
                    -bounds.center.z);
                animator.Update(0f);
                bounds = RenderBounds(renderers);

                Directory.CreateDirectory(Path.GetDirectoryName(screenshotPath) ?? ".");
                cameraObject = new GameObject("MaasoVrmSmokeCamera");
                Camera camera = cameraObject.AddComponent<Camera>();
                camera.clearFlags = CameraClearFlags.SolidColor;
                camera.backgroundColor = new Color(0.64f, 0.82f, 0.96f, 1f);
                camera.fieldOfView = 30f;
                camera.nearClipPlane = 0.01f;
                camera.farClipPlane = 50f;
                camera.aspect = 9f / 16f;
                CameraPose pose = FrontFullBodyCamera.CalculatePose(
                    bounds,
                    instance.transform.forward,
                    Vector3.up,
                    camera.fieldOfView,
                    camera.aspect,
                    1.08f,
                    0.25f);
                camera.transform.SetPositionAndRotation(pose.Position, pose.Rotation);

                keyLightObject = CreateDirectionalLight(
                    "MaasoVrmSmokeKey",
                    new Vector3(35f, -30f, 0f),
                    1.05f,
                    new Color(1f, 0.94f, 0.86f));
                fillLightObject = CreateDirectionalLight(
                    "MaasoVrmSmokeFill",
                    new Vector3(18f, 145f, 0f),
                    0.55f,
                    new Color(0.72f, 0.84f, 1f));
                RenderScreenshot(camera, screenshotPath, 720, 1280);

                var report = new SmokeReport
                {
                    modelName = Path.GetFileName(modelPath),
                    bytes = new FileInfo(modelPath).Length,
                    sha256 = ComputeSha256(modelPath),
                    humanoid = true,
                    rendererCount = renderers.Length,
                    heightMeters = bounds.size.y,
                    conservativeImportedHeightMeters = conservativeLoadedBounds.size.y,
                    authoredHeightMeters = expectedHeightMeters,
                    loadedHeightMeters = loadedBounds.size.y,
                    reboundHeightMeters = reboundBounds.size.y,
                    expressionHeightMeters = bounds.size.y,
                    authoredHeightRatio = expectedHeightRatio,
                    rebindHeightRatio = rebindHeightRatio,
                    expressionHeightRatio = expressionHeightRatio,
                    loadedHumanScale = loadedHumanScale,
                    reboundHumanScale = reboundHumanScale,
                    loadedMaxBoneScaleDeviation = loadedBoneScaleDeviation,
                    reboundMaxBoneScaleDeviation = reboundBoneScaleDeviation,
                    expressionMaxBoneScaleDeviation = expressionBoneScaleDeviation,
                    expressionCount = expression.ExpressionKeys.Count,
                    requiredExpressions = requiredExpressions
                        .Select(value => value.ToString())
                        .ToArray(),
                    maasoAnimatorController = controller.name,
                    screenshotPath = screenshotPath,
                    passed = validationErrors.Count == 0,
                    validationErrors = validationErrors.ToArray(),
                };
                Directory.CreateDirectory(Path.GetDirectoryName(reportPath) ?? ".");
                File.WriteAllText(reportPath, JsonUtility.ToJson(report, true));
                if (!report.passed)
                {
                    throw new InvalidOperationException(
                        "VRM smoke validation failed: " +
                        string.Join(" ", report.validationErrors));
                }
                Debug.Log(
                    $"[MaasoVrmSmoke] PASS {report.modelName}: " +
                    $"{report.heightMeters:F3}m, {report.rendererCount} renderers, " +
                    $"{report.expressionCount} expressions, sha256={report.sha256}");
            }
            finally
            {
                DestroyImmediate(fillLightObject);
                DestroyImmediate(keyLightObject);
                DestroyImmediate(cameraObject);
                if (instance != null)
                {
                    DestroyImmediate(instance.gameObject);
                }
            }
        }

        private static string RequiredArgument(string name)
        {
            string[] arguments = Environment.GetCommandLineArgs();
            int index = Array.IndexOf(arguments, name);
            if (index < 0 || index + 1 >= arguments.Length ||
                string.IsNullOrWhiteSpace(arguments[index + 1]))
            {
                throw new ArgumentException("Missing command line argument: " + name);
            }
            return Path.GetFullPath(arguments[index + 1]);
        }

        private static float OptionalFloatArgument(string name, float fallback)
        {
            string[] arguments = Environment.GetCommandLineArgs();
            int index = Array.IndexOf(arguments, name);
            if (index < 0)
            {
                return fallback;
            }
            if (index + 1 >= arguments.Length ||
                !float.TryParse(
                    arguments[index + 1],
                    NumberStyles.Float,
                    CultureInfo.InvariantCulture,
                    out float value) ||
                value <= 0f)
            {
                throw new ArgumentException(
                    "Invalid positive float command line argument: " + name);
            }
            return value;
        }

        private static Bounds RenderBounds(Renderer[] renderers)
        {
            Bounds bounds = default;
            bool hasBounds = false;
            for (int index = 0; index < renderers.Length; index++)
            {
                Bounds rendererBounds = CurrentGeometryBounds(renderers[index]);
                if (!hasBounds)
                {
                    bounds = rendererBounds;
                    hasBounds = true;
                }
                else
                {
                    bounds.Encapsulate(rendererBounds);
                }
            }
            return bounds;
        }

        private static Bounds CurrentGeometryBounds(Renderer renderer)
        {
            if (renderer is not SkinnedMeshRenderer skinnedRenderer ||
                skinnedRenderer.sharedMesh == null)
            {
                return renderer.bounds;
            }

            var bakedMesh = new Mesh { name = renderer.name + "-SmokeBounds" };
            try
            {
                skinnedRenderer.BakeMesh(bakedMesh);
                Vector3[] vertices = bakedMesh.vertices;
                if (vertices.Length == 0)
                {
                    return renderer.bounds;
                }
                Matrix4x4 localToWorld = renderer.transform.localToWorldMatrix;
                Bounds bounds = new Bounds(
                    localToWorld.MultiplyPoint3x4(vertices[0]),
                    Vector3.zero);
                for (int index = 1; index < vertices.Length; index++)
                {
                    bounds.Encapsulate(
                        localToWorld.MultiplyPoint3x4(vertices[index]));
                }
                return bounds;
            }
            finally
            {
                UnityEngine.Object.DestroyImmediate(bakedMesh);
            }
        }

        private static Bounds ConservativeRenderBounds(Renderer[] renderers)
        {
            Bounds bounds = renderers[0].bounds;
            for (int index = 1; index < renderers.Length; index++)
            {
                bounds.Encapsulate(renderers[index].bounds);
            }
            return bounds;
        }

        private static float MaxHumanoidBoneScaleDeviation(Animator animator)
        {
            float maximum = 0f;
            foreach (HumanBodyBones bone in Enum.GetValues(typeof(HumanBodyBones)))
            {
                if (bone == HumanBodyBones.LastBone)
                {
                    continue;
                }
                Transform transform = animator.GetBoneTransform(bone);
                if (transform == null)
                {
                    continue;
                }
                Vector3 scale = transform.localScale;
                maximum = Mathf.Max(
                    maximum,
                    Mathf.Abs(scale.x - 1f),
                    Mathf.Abs(scale.y - 1f),
                    Mathf.Abs(scale.z - 1f));
            }
            return maximum;
        }

        private static GameObject CreateDirectionalLight(
            string name,
            Vector3 rotation,
            float intensity,
            Color color)
        {
            var lightObject = new GameObject(name);
            lightObject.transform.eulerAngles = rotation;
            Light light = lightObject.AddComponent<Light>();
            light.type = LightType.Directional;
            light.intensity = intensity;
            light.color = color;
            light.shadows = LightShadows.Soft;
            return lightObject;
        }

        private static void RenderScreenshot(
            Camera camera,
            string outputPath,
            int width,
            int height)
        {
            RenderTexture renderTexture = RenderTexture.GetTemporary(
                width,
                height,
                24,
                RenderTextureFormat.ARGB32,
                RenderTextureReadWrite.sRGB);
            RenderTexture previous = RenderTexture.active;
            var image = new Texture2D(width, height, TextureFormat.RGB24, false);
            try
            {
                camera.targetTexture = renderTexture;
                camera.Render();
                RenderTexture.active = renderTexture;
                image.ReadPixels(new Rect(0f, 0f, width, height), 0, 0);
                image.Apply();
                File.WriteAllBytes(outputPath, image.EncodeToPNG());
            }
            finally
            {
                camera.targetTexture = null;
                RenderTexture.active = previous;
                UnityEngine.Object.DestroyImmediate(image);
                RenderTexture.ReleaseTemporary(renderTexture);
            }
        }

        private static string ComputeSha256(string path)
        {
            using FileStream stream = File.OpenRead(path);
            using SHA256 sha256 = SHA256.Create();
            return BitConverter.ToString(sha256.ComputeHash(stream))
                .Replace("-", string.Empty)
                .ToLowerInvariant();
        }

        private static void DestroyImmediate(GameObject value)
        {
            if (value != null)
            {
                UnityEngine.Object.DestroyImmediate(value);
            }
        }

        [Serializable]
        private sealed class SmokeReport
        {
            public string modelName;
            public long bytes;
            public string sha256;
            public bool humanoid;
            public int rendererCount;
            public float heightMeters;
            public float conservativeImportedHeightMeters;
            public float authoredHeightMeters;
            public float loadedHeightMeters;
            public float reboundHeightMeters;
            public float expressionHeightMeters;
            public float authoredHeightRatio;
            public float rebindHeightRatio;
            public float expressionHeightRatio;
            public float loadedHumanScale;
            public float reboundHumanScale;
            public float loadedMaxBoneScaleDeviation;
            public float reboundMaxBoneScaleDeviation;
            public float expressionMaxBoneScaleDeviation;
            public int expressionCount;
            public string[] requiredExpressions;
            public string maasoAnimatorController;
            public string screenshotPath;
            public bool passed;
            public string[] validationErrors;
        }
    }
}
#endif
