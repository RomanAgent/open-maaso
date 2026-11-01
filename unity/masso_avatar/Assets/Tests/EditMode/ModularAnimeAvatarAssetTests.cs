using System;
using System.Linq;
using NUnit.Framework;
using UnityEditor;
using UnityEngine;

namespace Maaso.Tests
{
    public sealed class ModularAnimeAvatarAssetTests
    {
        private const string ControllerPath =
            "Assets/MaasoAvatar/Animations/Humanoid/MaasoHumanoid.controller";
        private const string FemalePrefabPath =
            "Assets/MaasoAvatar/AvatarBundleSources/ModularAnime/Female.prefab";
        private const string RuntimeShaderName =
            "Maaso/Avatar/Modular Anime Mask Lit";

        [Test]
        public void RuntimeShaderIsAvailableAndCompiles()
        {
            Shader shader = Shader.Find(RuntimeShaderName);
            Assert.That(shader, Is.Not.Null, RuntimeShaderName);
            string messages = string.Join(
                "\n",
                ShaderUtil.GetShaderMessages(shader)
                    .Select(message => message.message));
            Assert.That(ShaderUtil.ShaderHasError(shader), Is.False, messages);
        }

        [TestCase(FemalePrefabPath)]

        public void RuntimePrefabUsesMaasoHumanoidController(string prefabPath)
        {
            GameObject prefab = AssetDatabase.LoadAssetAtPath<GameObject>(prefabPath);
            RuntimeAnimatorController controller =
                AssetDatabase.LoadAssetAtPath<RuntimeAnimatorController>(ControllerPath);

            Assert.That(prefab, Is.Not.Null, prefabPath);
            Assert.That(controller, Is.Not.Null, ControllerPath);
            Animator animator = prefab.GetComponentInChildren<Animator>(true);
            Assert.That(animator, Is.Not.Null);
            Assert.That(animator.avatar, Is.Not.Null);
            Assert.That(animator.avatar.isHuman, Is.True);
            Assert.That(animator.runtimeAnimatorController, Is.SameAs(controller));
            Assert.That(animator.applyRootMotion, Is.False);
        }

        [TestCase(FemalePrefabPath)]

        public void RuntimePrefabKeepsSkinnedMeshesVisible(string prefabPath)
        {
            GameObject prefab = AssetDatabase.LoadAssetAtPath<GameObject>(prefabPath);
            Assert.That(prefab, Is.Not.Null, prefabPath);

            SkinnedMeshRenderer[] renderers =
                prefab.GetComponentsInChildren<SkinnedMeshRenderer>(true);
            Assert.That(renderers, Is.Not.Empty);
            Assert.That(
                renderers.All(renderer => renderer.updateWhenOffscreen),
                Is.True);
        }

        [TestCase(FemalePrefabPath, "F_HeadSlot")]

        public void RuntimePrefabRebindsHeadToTheHumanoidSkeleton(
            string prefabPath,
            string headName)
        {
            GameObject prefab = AssetDatabase.LoadAssetAtPath<GameObject>(prefabPath);
            Assert.That(prefab, Is.Not.Null, prefabPath);

            SkinnedMeshRenderer[] renderers =
                prefab.GetComponentsInChildren<SkinnedMeshRenderer>(true);
            SkinnedMeshRenderer reference = renderers
                .Where(renderer =>
                    renderer.name.IndexOf("_body_", StringComparison.OrdinalIgnoreCase) >= 0)
                .OrderByDescending(renderer => renderer.bones.Length)
                .First();
            SkinnedMeshRenderer head = renderers
                .Single(renderer => renderer.name == headName);

            Assert.That(head.sharedMesh, Is.Not.Null);
            Assert.That(head.rootBone, Is.SameAs(reference.rootBone));
            Assert.That(head.bones, Is.EqualTo(reference.bones));
        }

        [TestCase(FemalePrefabPath, "C_hair_medium.001")]

        public void RuntimePrefabIncludesACompleteDefaultLook(
            string prefabPath,
            string hairName)
        {
            GameObject prefab = AssetDatabase.LoadAssetAtPath<GameObject>(prefabPath);
            Assert.That(prefab, Is.Not.Null, prefabPath);

            Transform[] transforms = prefab.GetComponentsInChildren<Transform>(true);
            Assert.That(
                transforms.Any(transform => transform.name == hairName),
                Is.True,
                "A bundled avatar must include visible hair.");
            Assert.That(
                transforms.Any(transform =>
                    transform.name == "Top10" &&
                    transform.gameObject.activeSelf),
                Is.True,
                "The default shirt must be enabled.");
            Assert.That(
                transforms.Any(transform =>
                    transform.name == "Bot4" &&
                    transform.gameObject.activeSelf),
                Is.True,
                "The default trousers must be enabled.");
            Assert.That(
                transforms.Any(transform =>
                    transform.name == "Shoes6" &&
                    transform.gameObject.activeSelf),
                Is.True,
                "The default shoes must be enabled.");
        }

        [TestCase(FemalePrefabPath, "F_body_torso.002", "F_body_legs_knee")]

        public void RuntimePrefabKeepsSkinForVisibleOutfitOpenings(
            string prefabPath,
            string upperChestRendererName,
            string kneeRendererName)
        {
            GameObject prefab = AssetDatabase.LoadAssetAtPath<GameObject>(prefabPath);
            Assert.That(prefab, Is.Not.Null, prefabPath);

            SkinnedMeshRenderer[] renderers =
                prefab.GetComponentsInChildren<SkinnedMeshRenderer>(true);
            SkinnedMeshRenderer upperChest = renderers.SingleOrDefault(
                renderer => renderer.name == upperChestRendererName);
            Assert.That(
                upperChest,
                Is.Not.Null,
                "The upper-chest/neck-root skin must remain under the shirt " +
                "collar so the head does not look detached.");
            Assert.That(upperChest.enabled, Is.True);
            Assert.That(upperChest.gameObject.activeSelf, Is.True);
            Assert.That(
                renderers.Select(renderer => renderer.name),
                Does.Contain(kneeRendererName),
                "The knee skin must remain under the ripped trousers.");
        }

        [TestCase(FemalePrefabPath, "F")]

        public void RuntimePrefabMatchesVendorBodyPartCoverage(
            string prefabPath,
            string genderPrefix)
        {
            GameObject prefab = AssetDatabase.LoadAssetAtPath<GameObject>(
                prefabPath);
            Assert.That(prefab, Is.Not.Null, prefabPath);

            string[] rendererNames = prefab
                .GetComponentsInChildren<SkinnedMeshRenderer>(true)
                .Select(renderer => renderer.name)
                .ToArray();
            string[] expectedVisibleSkin =
            {
                genderPrefix + "_body_torso.002",
                genderPrefix + "_body_hands",
                genderPrefix + "_body_legs_knee",
                genderPrefix + "_body_feet",
            };
            string[] expectedCoveredSkin =
            {
                genderPrefix + "_body_hips",
                genderPrefix + "_body_torso",
                genderPrefix + "_body_torso.001",
                genderPrefix + "_body_shoulders",
                genderPrefix + "_body_arms_lower",
                genderPrefix + "_body_arms_upper",
                genderPrefix + "_body_legs_upper",
                genderPrefix + "_body_legs_lower",
            };

            Assert.That(
                expectedVisibleSkin.Where(name =>
                    !rendererNames.Contains(name)),
                Is.Empty,
                "Skin at the collar, cuffs, ripped knees, and shoe openings " +
                "must remain visible.");
            Assert.That(
                expectedCoveredSkin.Where(rendererNames.Contains),
                Is.Empty,
                "Skin fully covered by Top.10 and Bot.04 must be removed to " +
                "prevent clothing intersections.");
        }

        [TestCase(FemalePrefabPath, "F_HeadSlot", "F_body_torso.002")]

        public void RuntimePrefabKeepsHeadConnectedThroughUpperChestDuringIdle(
            string prefabPath,
            string headRendererName,
            string upperChestRendererName)
        {
            GameObject prefab = AssetDatabase.LoadAssetAtPath<GameObject>(
                prefabPath);
            Assert.That(prefab, Is.Not.Null, prefabPath);

            GameObject instance = UnityEngine.Object.Instantiate(prefab);
            try
            {
                Animator animator =
                    instance.GetComponentInChildren<Animator>(true);
                AnimationClip idle = animator.runtimeAnimatorController
                    .animationClips
                    .Single(clip => clip.name == "idle_shrug");
                SkinnedMeshRenderer[] renderers =
                    instance.GetComponentsInChildren<SkinnedMeshRenderer>(true);
                SkinnedMeshRenderer head = renderers.Single(
                    renderer => renderer.name == headRendererName);
                SkinnedMeshRenderer upperChest = renderers.Single(
                    renderer => renderer.name == upperChestRendererName);
                SkinnedMeshRenderer shirt = renderers.Single(
                    renderer => renderer.name == "Top10");

                float[] normalizedTimes = { 0f, 0.25f, 0.5f, 0.75f };
                for (int index = 0;
                     index < normalizedTimes.Length;
                     index++)
                {
                    idle.SampleAnimation(
                        instance,
                        idle.length * normalizedTimes[index]);
                    Vector2 headY = WorldYRange(head);
                    Vector2 upperChestY = WorldYRange(upperChest);
                    Vector2 shirtY = WorldYRange(shirt);

                    Assert.That(
                        headY.x,
                        Is.LessThanOrEqualTo(upperChestY.y),
                        "The head neck must overlap the upper-chest/neck-root " +
                        "body mesh throughout the idle animation. " +
                        "normalizedTime=" + normalizedTimes[index] +
                        ", seam=" + (headY.x - upperChestY.y));
                    Assert.That(
                        upperChestY.x,
                        Is.LessThanOrEqualTo(shirtY.y),
                        "The upper-chest/neck-root body mesh must extend inside " +
                        "the shirt collar throughout the idle animation. " +
                        "normalizedTime=" + normalizedTimes[index] +
                        ", seam=" + (upperChestY.x - shirtY.y));
                }
            }
            finally
            {
                UnityEngine.Object.DestroyImmediate(instance);
            }
        }

        [TestCase(
            FemalePrefabPath,
            "F_body_legs_lower",
            "F_body_feet")]
        public void RuntimePrefabMatchesVendorCoverageAtTrouserAndShoeSeams(
            string prefabPath,
            string lowerLegRendererName,
            string feetRendererName)
        {
            GameObject prefab = AssetDatabase.LoadAssetAtPath<GameObject>(
                prefabPath);
            Assert.That(prefab, Is.Not.Null, prefabPath);

            GameObject instance = UnityEngine.Object.Instantiate(prefab);
            try
            {
                Animator animator =
                    instance.GetComponentInChildren<Animator>(true);
                SkinnedMeshRenderer[] renderers =
                    instance.GetComponentsInChildren<SkinnedMeshRenderer>(true);
                SkinnedMeshRenderer lowerLeg = renderers.SingleOrDefault(
                    renderer => renderer.name == lowerLegRendererName);
                SkinnedMeshRenderer feet = renderers.SingleOrDefault(
                    renderer => renderer.name == feetRendererName);
                SkinnedMeshRenderer trousers = renderers.Single(
                    renderer => renderer.name == "Bot4");
                SkinnedMeshRenderer shoes = renderers.Single(
                    renderer => renderer.name == "Shoes6");

                Assert.That(
                    lowerLeg,
                    Is.Null,
                    "The source Bot.04 customization metadata hides the lower " +
                    "legs to prevent skinny-jean clipping.");
                Assert.That(
                    feet,
                    Is.Not.Null,
                    "The feet must remain inside the shoes so the ankle seam " +
                    "cannot expose the background.");
                Assert.That(feet.enabled, Is.True);
                Assert.That(feet.gameObject.activeSelf, Is.True);

                string[] movementClips =
                {
                    "idle_shrug",
                    "standard_walk",
                    "female_stop_walking",
                };
                float[] normalizedTimes = { 0f, 0.25f, 0.5f, 0.75f };
                for (int clipIndex = 0;
                     clipIndex < movementClips.Length;
                     clipIndex++)
                {
                    AnimationClip clip = animator.runtimeAnimatorController
                        .animationClips
                        .Single(candidate =>
                            candidate.name == movementClips[clipIndex]);
                    for (int timeIndex = 0;
                         timeIndex < normalizedTimes.Length;
                         timeIndex++)
                    {
                        clip.SampleAnimation(
                            instance,
                            clip.length * normalizedTimes[timeIndex]);
                        AssertYRangesOverlap(
                            feet,
                            trousers,
                            "feet",
                            "trousers",
                            movementClips[clipIndex],
                            normalizedTimes[timeIndex]);
                        AssertYRangesOverlap(
                            feet,
                            shoes,
                            "feet",
                            "shoes",
                            movementClips[clipIndex],
                            normalizedTimes[timeIndex]);
                    }
                }
            }
            finally
            {
                UnityEngine.Object.DestroyImmediate(instance);
            }
        }

        [Test]
        public void RuntimeShaderSupportsTheSourceSixColorMaskContract()
        {
            Shader shader = Shader.Find(RuntimeShaderName);
            Assert.That(shader, Is.Not.Null, RuntimeShaderName);

            Material material = new Material(shader);
            try
            {
                string[] requiredProperties =
                {
                    "_BaseMap",
                    "_Color_A_1",
                    "_Color_A_2",
                    "_Color_B_1",
                    "_Color_B_2",
                    "_Color_C_1",
                    "_Color_C_2",
                    "_MaskRemap",
                    "_Mask_Factor",
                };
                Assert.That(
                    requiredProperties.Where(property =>
                        !material.HasProperty(property)),
                    Is.Empty,
                    "The runtime shader must preserve the source Shader Graph " +
                    "palette and mask-selection properties.");
            }
            finally
            {
                UnityEngine.Object.DestroyImmediate(material);
            }
        }

        [TestCase(FemalePrefabPath)]

        public void RuntimePrefabOmitsUnusedEquipment(string prefabPath)
        {
            GameObject prefab = AssetDatabase.LoadAssetAtPath<GameObject>(prefabPath);
            Assert.That(prefab, Is.Not.Null, prefabPath);

            string[] names = prefab
                .GetComponentsInChildren<Transform>(true)
                .Select(transform => transform.name)
                .ToArray();
            Assert.That(names, Does.Not.Contain("Top1"));
            Assert.That(names, Does.Not.Contain("Top11"));
            Assert.That(names, Does.Not.Contain("Bot1"));
            Assert.That(names, Does.Not.Contain("Shoes1"));
            Assert.That(names.Any(name =>
                name.StartsWith("Outfit", StringComparison.Ordinal)), Is.False);
        }

        [TestCase(FemalePrefabPath)]

        public void RuntimePrefabUsesSupportedMaterials(string prefabPath)
        {
            GameObject prefab = AssetDatabase.LoadAssetAtPath<GameObject>(prefabPath);
            Assert.That(prefab, Is.Not.Null, prefabPath);

            Material[] materials = prefab
                .GetComponentsInChildren<Renderer>(true)
                .SelectMany(renderer => renderer.sharedMaterials)
                .Distinct()
                .ToArray();

            Assert.That(materials, Is.Not.Empty);
            Assert.That(materials.All(material => material != null), Is.True);
            string[] invalidMaterials = materials
                .Where(material =>
                    material.shader == null ||
                    material.shader.name == "Hidden/InternalErrorShader")
                .Select(material =>
                    material.name + " (" +
                    (material.shader == null ? "missing" : material.shader.name) +
                    ")")
                .ToArray();
            Assert.That(
                invalidMaterials,
                Is.Empty,
                string.Join(", ", invalidMaterials));
        }

        [TestCase(FemalePrefabPath, "mat_base_F_body")]

        public void RuntimeBodyMaterialKeepsItsOriginalColorMask(
            string prefabPath,
            string materialName)
        {
            GameObject prefab = AssetDatabase.LoadAssetAtPath<GameObject>(prefabPath);
            Assert.That(prefab, Is.Not.Null, prefabPath);

            Material material = prefab
                .GetComponentsInChildren<Renderer>(true)
                .SelectMany(renderer => renderer.sharedMaterials)
                .FirstOrDefault(candidate =>
                    candidate != null &&
                    candidate.name == materialName);

            Assert.That(material, Is.Not.Null, materialName);
            Assert.That(material.shader.name, Is.EqualTo(RuntimeShaderName));
            Assert.That(material.GetTexture("_BaseMap"), Is.Not.Null);
            Assert.That(material.GetFloat("_UseMask"), Is.EqualTo(1f));
        }

        [TestCase(FemalePrefabPath)]

        public void RuntimePrefabRendersVisibleHeadAndBodyPixels(string prefabPath)
        {
            GameObject prefab = AssetDatabase.LoadAssetAtPath<GameObject>(prefabPath);
            Assert.That(prefab, Is.Not.Null, prefabPath);

            GameObject instance = UnityEngine.Object.Instantiate(prefab);
            var cameraObject = new GameObject("Avatar Render Test Camera");
            var lightObject = new GameObject("Avatar Render Test Light");
            RenderTexture target = null;
            Texture2D capture = null;
            try
            {
                instance.transform.SetPositionAndRotation(
                    Vector3.zero,
                    Quaternion.identity);
                Bounds bounds = VisualBounds(instance);

                Camera camera = cameraObject.AddComponent<Camera>();
                camera.clearFlags = CameraClearFlags.SolidColor;
                camera.backgroundColor = Color.magenta;
                camera.fieldOfView = 28f;
                camera.aspect = 2f / 3f;
                camera.nearClipPlane = 0.01f;
                camera.farClipPlane = 100f;
                float halfFov = camera.fieldOfView * Mathf.Deg2Rad * 0.5f;
                float verticalDistance = bounds.extents.y / Mathf.Tan(halfFov);
                float horizontalDistance =
                    bounds.extents.x / (Mathf.Tan(halfFov) * camera.aspect);
                float distance = Mathf.Max(
                    Mathf.Max(verticalDistance, horizontalDistance) * 1.12f,
                    2f);
                cameraObject.transform.position =
                    bounds.center + Vector3.forward * distance;
                cameraObject.transform.LookAt(bounds.center);

                Light light = lightObject.AddComponent<Light>();
                light.type = LightType.Directional;
                light.intensity = 1.1f;
                lightObject.transform.rotation =
                    Quaternion.Euler(35f, 150f, 0f);

                target = new RenderTexture(256, 384, 24);
                camera.targetTexture = target;
                camera.Render();
                RenderTexture previous = RenderTexture.active;
                RenderTexture.active = target;
                capture = new Texture2D(
                    target.width,
                    target.height,
                    TextureFormat.RGB24,
                    false);
                capture.ReadPixels(
                    new Rect(0, 0, target.width, target.height),
                    0,
                    0);
                capture.Apply();
                RenderTexture.active = previous;
                camera.targetTexture = null;
                Color capturedBackground = capture.GetPixel(0, 0);

                int visibleHeadPixels = CountNonBackgroundPixels(
                    capture,
                    0.35f,
                    0.65f,
                    0.68f,
                    0.9f,
                    capturedBackground);
                int visibleBodyPixels = CountNonBackgroundPixels(
                    capture,
                    0.25f,
                    0.75f,
                    0.2f,
                    0.68f,
                    capturedBackground);
                Assert.That(
                    visibleHeadPixels,
                    Is.GreaterThan(100),
                    "The bundled avatar head and eyes must render, not only its clothes.");
                Assert.That(
                    visibleBodyPixels,
                    Is.GreaterThan(500),
                    "The bundled avatar body must render visibly.");
            }
            finally
            {
                if (capture != null)
                {
                    UnityEngine.Object.DestroyImmediate(capture);
                }
                if (target != null)
                {
                    UnityEngine.Object.DestroyImmediate(target);
                }
                UnityEngine.Object.DestroyImmediate(lightObject);
                UnityEngine.Object.DestroyImmediate(cameraObject);
                UnityEngine.Object.DestroyImmediate(instance);
            }
        }

        [TestCase(FemalePrefabPath)]

        public void RuntimeFaceProvidesMaasoLipAndBlinkInputs(string prefabPath)
        {
            GameObject prefab =
                AssetDatabase.LoadAssetAtPath<GameObject>(prefabPath);
            Assert.That(prefab, Is.Not.Null, prefabPath);

            string[] blendShapeNames = prefab
                .GetComponentsInChildren<SkinnedMeshRenderer>(true)
                .Where(renderer => renderer.sharedMesh != null)
                .SelectMany(renderer => Enumerable.Range(
                    0,
                    renderer.sharedMesh.blendShapeCount)
                    .Select(renderer.sharedMesh.GetBlendShapeName))
                .Distinct(StringComparer.Ordinal)
                .ToArray();

            Assert.That(blendShapeNames, Does.Contain("phoneme_Ah"));
            Assert.That(blendShapeNames, Does.Contain("jaw_open"));
            Assert.That(
                blendShapeNames.Any(name =>
                    name.StartsWith("eyes_closed.", StringComparison.Ordinal)),
                Is.True);
        }

        private static Vector2 WorldYRange(SkinnedMeshRenderer renderer)
        {
            Mesh baked = new Mesh();
            renderer.BakeMesh(baked);
            try
            {
                Vector3[] vertices = baked.vertices;
                float minimum = float.PositiveInfinity;
                float maximum = float.NegativeInfinity;
                for (int index = 0; index < vertices.Length; index++)
                {
                    float worldY = renderer.transform
                        .TransformPoint(vertices[index])
                        .y;
                    minimum = Mathf.Min(minimum, worldY);
                    maximum = Mathf.Max(maximum, worldY);
                }
                return new Vector2(minimum, maximum);
            }
            finally
            {
                UnityEngine.Object.DestroyImmediate(baked);
            }
        }

        private static void AssertYRangesOverlap(
            SkinnedMeshRenderer first,
            SkinnedMeshRenderer second,
            string firstLabel,
            string secondLabel,
            string clipName,
            float normalizedTime)
        {
            Vector2 firstY = WorldYRange(first);
            Vector2 secondY = WorldYRange(second);
            bool overlaps =
                firstY.x <= secondY.y &&
                secondY.x <= firstY.y;
            Assert.That(
                overlaps,
                Is.True,
                firstLabel +
                " must overlap " +
                secondLabel +
                " during " +
                clipName +
                " at normalizedTime=" +
                normalizedTime +
                ". " +
                firstLabel +
                "=" +
                firstY +
                ", " +
                secondLabel +
                "=" +
                secondY);
        }

        private static Bounds VisualBounds(GameObject instance)
        {
            Renderer[] renderers =
                instance.GetComponentsInChildren<Renderer>(true);
            Assert.That(renderers, Is.Not.Empty);

            Bounds bounds = renderers[0].bounds;
            for (int index = 1; index < renderers.Length; index++)
            {
                bounds.Encapsulate(renderers[index].bounds);
            }
            return bounds;
        }

        private static int CountNonBackgroundPixels(
            Texture2D capture,
            float minX,
            float maxX,
            float minY,
            float maxY,
            Color background)
        {
            int xStart = Mathf.FloorToInt(capture.width * minX);
            int xEnd = Mathf.CeilToInt(capture.width * maxX);
            int yStart = Mathf.FloorToInt(capture.height * minY);
            int yEnd = Mathf.CeilToInt(capture.height * maxY);
            Color32 expected = background;
            Color32[] pixels = capture.GetPixels32();
            int count = 0;
            for (int y = yStart; y < yEnd; y++)
            {
                for (int x = xStart; x < xEnd; x++)
                {
                    Color32 pixel = pixels[y * capture.width + x];
                    if (Mathf.Abs(pixel.r - expected.r) > 4 ||
                        Mathf.Abs(pixel.g - expected.g) > 4 ||
                        Mathf.Abs(pixel.b - expected.b) > 4)
                    {
                        count++;
                    }
                }
            }
            return count;
        }
    }
}
