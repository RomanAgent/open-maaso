using System;
using System.Collections.Generic;
using System.Text;
using UniGLTF.Extensions.VRMC_vrm;
using UniVRM10;
using UnityEngine;

namespace Maaso.Avatar
{
    public static class AvatarCapabilityIssueCodes
    {
        public const string MissingHumanoid = "missing_humanoid";
        public const string MissingRenderable = "missing_renderable";
        public const string MissingHead = "missing_head";
        public const string MissingLeftEye = "missing_left_eye";
        public const string MissingRightEye = "missing_right_eye";
        public const string MissingLookAt = "missing_look_at";
        public const string MissingLipSync = "missing_lip_sync";
        public const string MissingBlink = "missing_blink";
        public const string MissingExpressions = "missing_expressions";
        public const string HighVertexCount = "high_vertex_count";
        public const string HighMaterialCount = "high_material_count";
        public const string HighTextureMemory = "high_texture_memory";

        internal static bool TryGetSeverity(string code, out string severity)
        {
            switch (code)
            {
                case MissingHumanoid:
                case MissingRenderable:
                case MissingHead:
                    severity = AvatarCapabilitySeverities.Blocker;
                    return true;
                case MissingLeftEye:
                case MissingRightEye:
                case MissingLookAt:
                case MissingLipSync:
                case MissingBlink:
                case MissingExpressions:
                case HighVertexCount:
                case HighMaterialCount:
                case HighTextureMemory:
                    severity = AvatarCapabilitySeverities.Warning;
                    return true;
                default:
                    severity = string.Empty;
                    return false;
            }
        }
    }

    internal static class AvatarCapabilitySeverities
    {
        internal const string Warning = "warning";
        internal const string Blocker = "blocker";
    }

    internal static class AvatarCapabilityStates
    {
        internal const string Supported = "supported";
        internal const string Degraded = "degraded";
        internal const string Incompatible = "incompatible";
    }

    [Serializable]
    public sealed class AvatarCapabilityIssue
    {
        [SerializeField] private string code;
        [SerializeField] private string severity;

        internal AvatarCapabilityIssue(string code, string severity)
        {
            this.code = code;
            this.severity = severity;
        }

        public string Code => code;
        public string Severity => severity;
    }

    [Serializable]
    public sealed class AvatarCapabilityRig
    {
        [SerializeField] private bool humanoid;
        [SerializeField] private bool head;
        [SerializeField] private bool leftEye;
        [SerializeField] private bool rightEye;

        internal AvatarCapabilityRig(bool humanoid, bool head, bool leftEye, bool rightEye)
        {
            this.humanoid = humanoid;
            this.head = head;
            this.leftEye = leftEye;
            this.rightEye = rightEye;
        }

        public bool Humanoid => humanoid;
        public bool Head => head;
        public bool LeftEye => leftEye;
        public bool RightEye => rightEye;
    }

    [Serializable]
    public sealed class AvatarCapabilityBehavior
    {
        [SerializeField] private bool lookAt;
        [SerializeField] private bool lipSync;
        [SerializeField] private bool blink;
        [SerializeField] private bool expressions;

        internal AvatarCapabilityBehavior(
            bool lookAt,
            bool lipSync,
            bool blink,
            bool expressions)
        {
            this.lookAt = lookAt;
            this.lipSync = lipSync;
            this.blink = blink;
            this.expressions = expressions;
        }

        public bool LookAt => lookAt;
        public bool LipSync => lipSync;
        public bool Blink => blink;
        public bool Expressions => expressions;
    }

    [Serializable]
    public sealed class AvatarCapabilityRenderMetrics
    {
        [SerializeField] private bool renderable;
        [SerializeField] private int rendererCount;
        [SerializeField] private int skinnedMeshCount;
        [SerializeField] private int vertexCount;
        [SerializeField] private int triangleCount;
        [SerializeField] private int materialCount;
        [SerializeField] private int textureCount;
        [SerializeField] private int maxTextureSize;
        [SerializeField] private long estimatedTextureBytes;

        internal AvatarCapabilityRenderMetrics(RenderScan scan)
        {
            renderable = scan.Renderable;
            rendererCount = scan.RendererCount;
            skinnedMeshCount = scan.SkinnedMeshCount;
            vertexCount = scan.VertexCount;
            triangleCount = scan.TriangleCount;
            materialCount = scan.MaterialCount;
            textureCount = scan.TextureCount;
            maxTextureSize = scan.MaxTextureSize;
            estimatedTextureBytes = scan.EstimatedTextureBytes;
        }

        public bool Renderable => renderable;
        public int RendererCount => rendererCount;
        public int SkinnedMeshCount => skinnedMeshCount;
        public int VertexCount => vertexCount;
        public int TriangleCount => triangleCount;
        public int MaterialCount => materialCount;
        public int TextureCount => textureCount;
        public int MaxTextureSize => maxTextureSize;
        public long EstimatedTextureBytes => estimatedTextureBytes;
    }

    [Serializable]
    public sealed class AvatarCapabilityProfile
    {
        [SerializeField] private int schemaVersion;
        [SerializeField] private string source;
        [SerializeField] private string state;
        [SerializeField] private AvatarCapabilityRig rig;
        [SerializeField] private AvatarCapabilityBehavior behavior;
        [SerializeField] private AvatarCapabilityRenderMetrics render;
        [SerializeField] private AvatarCapabilityIssue[] issues;

        internal AvatarCapabilityProfile(
            int schemaVersion,
            string source,
            string state,
            AvatarCapabilityRig rig,
            AvatarCapabilityBehavior behavior,
            AvatarCapabilityRenderMetrics render,
            AvatarCapabilityIssue[] issues)
        {
            this.schemaVersion = schemaVersion;
            this.source = source;
            this.state = state;
            this.rig = rig;
            this.behavior = behavior;
            this.render = render;
            this.issues = issues ?? Array.Empty<AvatarCapabilityIssue>();
        }

        public int SchemaVersion => schemaVersion;
        public string Source => source;
        public string State => state;
        public AvatarCapabilityRig Rig => rig;
        public AvatarCapabilityBehavior Behavior => behavior;
        public AvatarCapabilityRenderMetrics Render => render;
        public IReadOnlyList<AvatarCapabilityIssue> Issues => issues;
        public bool HasBlockingIssues => state == AvatarCapabilityStates.Incompatible;
        public bool HasBlockers => HasBlockingIssues;
    }

    /// <summary>
    /// Produces a bounded, code-only capability profile for a loaded candidate.
    /// It has no side effects on the active Avatar. The load path must invoke
    /// ProbeCandidate before replacing the currently active instance.
    /// </summary>
    public static class AvatarCapabilityProbe
    {
        public const int CurrentSchemaVersion = 1;
        public const int MaximumSerializedBytes = 8 * 1024;
        public const int MaximumIssues = 16;
        public const int MaximumRendererCount = 4096;
        public const int MaximumSkinnedMeshCount = 2048;
        public const int MaximumVertexCount = 10 * 1000 * 1000;
        public const int MaximumTriangleCount = 20 * 1000 * 1000;
        public const int MaximumMaterialCount = 8192;
        public const int MaximumTextureCount = 8192;
        public const int MaximumTextureSize = 16384;
        public const long MaximumEstimatedTextureBytes = 2L * 1024 * 1024 * 1024;

        public const string PendingLoadIntegration =
            "probe_candidate_before_activation";

        private const string UnitySource = "unity";
        private const int HighVertexThreshold = 150000;
        private const int HighTriangleThreshold = 300000;
        private const int HighMaterialThreshold = 32;
        private const int HighTextureCountThreshold = 64;
        private const int HighTextureSizeThreshold = 4096;
        private const long HighTextureMemoryThreshold = 256L * 1024 * 1024;
        private const int MaximumTexturePropertiesPerMaterial = 64;
        private const int MaximumBlendShapesPerMesh = 1024;
        private const int MaximumSubMeshesPerMesh = 1024;
        private const int MaximumTextureLayers = 2048;
        private const int MaximumMipLevels = 16;

        private static readonly string[] MouthBlendShapeAliases =
        {
            "A",
            "Fcl_MTH_A",
            "V_Open",
            "mouthOpen1",
            "mouthOpen2",
            "Jaw",
            "vrc.v_aa",
            "phoneme_Ah",
            "jaw_open",
        };

        private static readonly string[] BlinkBlendShapeAliases =
        {
            "Blink",
            "Blink1_L",
            "Blink1_R",
            "Blink2_L",
            "Blink2_R",
            "Eye_Blink_L",
            "Eye_Blink_R",
            "eyes_closed.01",
            "eyes_closed.02",
            "eyes_closed.03",
        };

        private static readonly string[] HappyBlendShapeAliases =
        {
            "Fun",
            "Joy(Yaeba)",
            "Smile_L",
            "Smile_R",
            "Mouth_Smile_L",
            "Mouth_Smile_R",
            "Facial_Smile_Default",
        };

        private static readonly string[] SadBlendShapeAliases =
        {
            "Brow_Raise_Inner_L",
            "Brow_Raise_Inner_R",
            "mayuge1_L",
            "mayuge1_R",
            "tareme",
        };

        private static readonly string[] AngryBlendShapeAliases =
        {
            "Brow_Drop_L",
            "Brow_Drop_R",
            "Angry",
            "Facial_Angry1",
            "Facial_Angry2",
            "tsurime",
        };

        private static readonly string[] SurprisedBlendShapeAliases =
        {
            "Eye_Wide_L",
            "Eye_Wide_R",
            "V_Tight_O",
            "mouthOpen2",
            "O",
            "Fcl_MTH_O",
        };

        private static readonly string[] RelaxedBlendShapeAliases =
        {
            "Eye_Squint_L",
            "Eye_Squint_R",
            "Lower_Eyelid1_L",
            "Lower_Eyelid1_R",
        };

        public static AvatarCapabilityProfile ProbeCandidate(GameObject candidateRoot)
        {
            return Probe(candidateRoot);
        }

        public static AvatarCapabilityProfile Probe(
            GameObject candidateRoot,
            Vrm10Instance vrm = null)
        {
            var issues = new List<AvatarCapabilityIssue>(MaximumIssues);
            Animator animator = candidateRoot == null
                ? null
                : candidateRoot.GetComponentInChildren<Animator>(true);
            bool humanoid = animator != null && animator.avatar != null &&
                animator.avatar.isHuman && animator.avatar.isValid;
            bool head = humanoid && HasBone(animator, HumanBodyBones.Head);
            bool leftEye = humanoid && HasBone(animator, HumanBodyBones.LeftEye);
            bool rightEye = humanoid && HasBone(animator, HumanBodyBones.RightEye);
            Vrm10Instance candidateVrm = vrm ?? candidateRoot
                ?.GetComponentInChildren<Vrm10Instance>(true);

            RenderScan render = ScanRenderers(candidateRoot);
            ExpressionSupport expression = ScanExpressions(
                candidateRoot,
                render.Meshes,
                candidateVrm,
                leftEye,
                rightEye);
            bool lookAt = candidateVrm != null
                ? expression.VrmLookAt
                : leftEye && rightEye;
            bool expressions = expression.Happy && expression.Sad &&
                expression.Angry && expression.Surprised && expression.Relaxed;

            AddMissingIssue(issues, humanoid, AvatarCapabilityIssueCodes.MissingHumanoid);
            AddMissingIssue(issues, render.Renderable, AvatarCapabilityIssueCodes.MissingRenderable);
            AddMissingIssue(issues, head, AvatarCapabilityIssueCodes.MissingHead);
            AddMissingIssue(issues, leftEye, AvatarCapabilityIssueCodes.MissingLeftEye);
            AddMissingIssue(issues, rightEye, AvatarCapabilityIssueCodes.MissingRightEye);
            AddMissingIssue(issues, lookAt, AvatarCapabilityIssueCodes.MissingLookAt);
            AddMissingIssue(issues, expression.LipSync, AvatarCapabilityIssueCodes.MissingLipSync);
            AddMissingIssue(issues, expression.Blink, AvatarCapabilityIssueCodes.MissingBlink);
            AddMissingIssue(issues, expressions, AvatarCapabilityIssueCodes.MissingExpressions);

            if (render.VertexCount >= HighVertexThreshold ||
                render.TriangleCount >= HighTriangleThreshold)
            {
                AddIssue(issues, AvatarCapabilityIssueCodes.HighVertexCount);
            }
            if (render.MaterialCount >= HighMaterialThreshold)
            {
                AddIssue(issues, AvatarCapabilityIssueCodes.HighMaterialCount);
            }
            if (render.TextureCount >= HighTextureCountThreshold ||
                render.MaxTextureSize >= HighTextureSizeThreshold ||
                render.EstimatedTextureBytes >= HighTextureMemoryThreshold)
            {
                AddIssue(issues, AvatarCapabilityIssueCodes.HighTextureMemory);
            }

            string state = DeriveState(issues);
            return new AvatarCapabilityProfile(
                CurrentSchemaVersion,
                UnitySource,
                state,
                new AvatarCapabilityRig(humanoid, head, leftEye, rightEye),
                new AvatarCapabilityBehavior(
                    lookAt,
                    expression.LipSync,
                    expression.Blink,
                    expressions),
                new AvatarCapabilityRenderMetrics(render),
                issues.ToArray());
        }

        /// <summary>
        /// A missing legacy profile is advisory and never blocks activation.
        /// Only a present profile with blocker issues may reject a candidate.
        /// </summary>
        public static bool BlocksActivation(AvatarCapabilityProfile profile)
        {
            return profile != null && profile.HasBlockingIssues;
        }

        public static string ToJson(AvatarCapabilityProfile profile)
        {
            if (profile == null)
            {
                throw new ArgumentNullException(nameof(profile));
            }

            string json = JsonUtility.ToJson(profile);
            if (Encoding.UTF8.GetByteCount(json) > MaximumSerializedBytes)
            {
                throw new InvalidOperationException(
                    "Avatar capability profile exceeds its transport budget.");
            }
            return json;
        }

        private static string DeriveState(List<AvatarCapabilityIssue> issues)
        {
            bool hasWarnings = false;
            for (int index = 0; index < issues.Count; index += 1)
            {
                if (issues[index].Severity == AvatarCapabilitySeverities.Blocker)
                {
                    return AvatarCapabilityStates.Incompatible;
                }
                hasWarnings = true;
            }
            return hasWarnings
                ? AvatarCapabilityStates.Degraded
                : AvatarCapabilityStates.Supported;
        }

        private static void AddMissingIssue(
            List<AvatarCapabilityIssue> issues,
            bool available,
            string code)
        {
            if (!available)
            {
                AddIssue(issues, code);
            }
        }

        private static void AddIssue(List<AvatarCapabilityIssue> issues, string code)
        {
            if (!AvatarCapabilityIssueCodes.TryGetSeverity(code, out string severity))
            {
                throw new ArgumentOutOfRangeException(nameof(code));
            }
            for (int index = 0; index < issues.Count; index += 1)
            {
                if (issues[index].Code == code)
                {
                    return;
                }
            }
            if (issues.Count >= MaximumIssues)
            {
                return;
            }
            issues.Add(new AvatarCapabilityIssue(code, severity));
        }

        private static bool HasBone(Animator animator, HumanBodyBones bone)
        {
            try
            {
                return animator.GetBoneTransform(bone) != null;
            }
            catch (InvalidOperationException)
            {
                return false;
            }
        }

        private static RenderScan ScanRenderers(GameObject candidateRoot)
        {
            var scan = new RenderScan();
            if (candidateRoot == null)
            {
                return scan;
            }

            Renderer[] renderers = candidateRoot.GetComponentsInChildren<Renderer>(true);
            var meshes = new HashSet<Mesh>();
            var materials = new HashSet<Material>();
            var textures = new HashSet<Texture>();
            bool hasBounds = false;
            Bounds bounds = default;
            int rendererLimit = Math.Min(renderers.Length, MaximumRendererCount);

            for (int rendererIndex = 0; rendererIndex < rendererLimit; rendererIndex += 1)
            {
                Renderer renderer = renderers[rendererIndex];
                if (renderer == null || !renderer.enabled)
                {
                    continue;
                }

                scan.RendererCount = SaturatingIncrement(
                    scan.RendererCount,
                    MaximumRendererCount);
                Mesh mesh = ResolveMesh(renderer);
                if (mesh == null || mesh.vertexCount <= 0)
                {
                    continue;
                }

                if (renderer is SkinnedMeshRenderer)
                {
                    scan.SkinnedMeshCount = SaturatingIncrement(
                        scan.SkinnedMeshCount,
                        MaximumSkinnedMeshCount);
                }
                if (meshes.Count < MaximumSkinnedMeshCount && meshes.Add(mesh))
                {
                    scan.Meshes.Add(mesh);
                    scan.VertexCount = SaturatingAdd(
                        scan.VertexCount,
                        mesh.vertexCount,
                        MaximumVertexCount);
                    scan.TriangleCount = SaturatingAdd(
                        scan.TriangleCount,
                        CountTriangles(mesh),
                        MaximumTriangleCount);
                }

                bool hasUsableMaterial = ScanMaterials(
                    renderer,
                    scan,
                    materials,
                    textures);
                if (!hasUsableMaterial)
                {
                    continue;
                }

                Bounds rendererBounds = renderer.bounds;
                if (!IsFiniteBounds(rendererBounds))
                {
                    continue;
                }
                if (!hasBounds)
                {
                    bounds = rendererBounds;
                    hasBounds = true;
                }
                else
                {
                    bounds.Encapsulate(rendererBounds);
                }
                scan.Renderable = true;
            }

            if (!hasBounds || bounds.size.y < 0.5f || bounds.size.y > 4f)
            {
                scan.Renderable = false;
            }
            return scan;
        }

        private static Mesh ResolveMesh(Renderer renderer)
        {
            if (renderer is SkinnedMeshRenderer skinned)
            {
                return skinned.sharedMesh;
            }
            if (renderer is MeshRenderer)
            {
                MeshFilter filter = renderer.GetComponent<MeshFilter>();
                return filter == null ? null : filter.sharedMesh;
            }
            return null;
        }

        private static bool ScanMaterials(
            Renderer renderer,
            RenderScan scan,
            HashSet<Material> materialSet,
            HashSet<Texture> textureSet)
        {
            bool hasUsableMaterial = false;
            Material[] materials = renderer.sharedMaterials;
            int materialLimit = Math.Min(materials.Length, MaximumMaterialCount);
            for (int materialIndex = 0; materialIndex < materialLimit; materialIndex += 1)
            {
                Material material = materials[materialIndex];
                if (material == null || material.shader == null)
                {
                    continue;
                }
                hasUsableMaterial = true;
                if (!materialSet.Add(material))
                {
                    continue;
                }

                scan.MaterialCount = SaturatingIncrement(
                    scan.MaterialCount,
                    MaximumMaterialCount);
                ScanTextures(material, scan, textureSet);
            }
            return hasUsableMaterial;
        }

        private static void ScanTextures(
            Material material,
            RenderScan scan,
            HashSet<Texture> textureSet)
        {
            string[] propertyNames;
            try
            {
                propertyNames = material.GetTexturePropertyNames();
            }
            catch (Exception)
            {
                return;
            }

            int propertyLimit = Math.Min(
                propertyNames.Length,
                MaximumTexturePropertiesPerMaterial);
            for (int propertyIndex = 0; propertyIndex < propertyLimit; propertyIndex += 1)
            {
                Texture texture;
                try
                {
                    texture = material.GetTexture(propertyNames[propertyIndex]);
                }
                catch (Exception)
                {
                    continue;
                }
                if (texture == null || textureSet.Count >= MaximumTextureCount ||
                    !textureSet.Add(texture))
                {
                    continue;
                }

                scan.TextureCount = SaturatingIncrement(
                    scan.TextureCount,
                    MaximumTextureCount);
                int dimension = Math.Max(texture.width, texture.height);
                scan.MaxTextureSize = Math.Min(
                    MaximumTextureSize,
                    Math.Max(scan.MaxTextureSize, dimension));
                scan.EstimatedTextureBytes = SaturatingAdd(
                    scan.EstimatedTextureBytes,
                    EstimateTextureBytes(texture),
                    MaximumEstimatedTextureBytes);
            }
        }

        private static long EstimateTextureBytes(Texture texture)
        {
            int width = Math.Max(1, Math.Min(texture.width, MaximumTextureSize));
            int height = Math.Max(1, Math.Min(texture.height, MaximumTextureSize));
            int layers = TextureLayerCount(texture);
            int mipCount = Math.Max(1, Math.Min(texture.mipmapCount, MaximumMipLevels));
            long bytes = 0;
            for (int mip = 0; mip < mipCount; mip += 1)
            {
                long mipBytes = (long)width * height * 4L * layers;
                bytes = SaturatingAdd(
                    bytes,
                    mipBytes,
                    MaximumEstimatedTextureBytes);
                if (bytes >= MaximumEstimatedTextureBytes)
                {
                    break;
                }
                width = Math.Max(1, width / 2);
                height = Math.Max(1, height / 2);
            }
            return bytes;
        }

        private static int TextureLayerCount(Texture texture)
        {
            if (texture is Cubemap)
            {
                return 6;
            }
            if (texture is Texture2DArray array)
            {
                return Math.Max(1, Math.Min(array.depth, MaximumTextureLayers));
            }
            if (texture is Texture3D volume)
            {
                return Math.Max(1, Math.Min(volume.depth, MaximumTextureLayers));
            }
            if (texture is RenderTexture renderTexture)
            {
                return Math.Max(
                    1,
                    Math.Min(renderTexture.volumeDepth, MaximumTextureLayers));
            }
            return 1;
        }

        private static int CountTriangles(Mesh mesh)
        {
            long count = 0;
            int subMeshLimit = Math.Min(mesh.subMeshCount, MaximumSubMeshesPerMesh);
            for (int subMesh = 0; subMesh < subMeshLimit; subMesh += 1)
            {
                try
                {
                    count = SaturatingAdd(
                        count,
                        (long)mesh.GetIndexCount(subMesh) / 3L,
                        MaximumTriangleCount);
                }
                catch (Exception)
                {
                    break;
                }
            }
            return (int)count;
        }

        private static ExpressionSupport ScanExpressions(
            GameObject candidateRoot,
            List<Mesh> meshes,
            Vrm10Instance providedVrm,
            bool leftEye,
            bool rightEye)
        {
            var support = new ExpressionSupport();
            if (candidateRoot != null)
            {
                try
                {
                    Vrm10Instance instance = providedVrm == null
                        ? candidateRoot.GetComponentInChildren<Vrm10Instance>(true)
                        : providedVrm;
                    if (instance != null && instance.Runtime != null)
                    {
                        IReadOnlyList<ExpressionKey> keys =
                            instance.Runtime.Expression?.ExpressionKeys;
                        support.VrmLookAt = SupportsVrmLookAt(
                            instance,
                            keys,
                            leftEye,
                            rightEye);
                        if (keys != null)
                        {
                            support.LipSync = ContainsExpression(keys, ExpressionKey.Aa);
                            support.Blink = ContainsExpression(keys, ExpressionKey.Blink) ||
                                ContainsExpression(keys, ExpressionKey.BlinkLeft) ||
                                ContainsExpression(keys, ExpressionKey.BlinkRight);
                            support.Happy = ContainsExpression(keys, ExpressionKey.Happy);
                            support.Sad = ContainsExpression(keys, ExpressionKey.Sad);
                            support.Angry = ContainsExpression(keys, ExpressionKey.Angry);
                            support.Surprised = ContainsExpression(
                                keys,
                                ExpressionKey.Surprised);
                            support.Relaxed = ContainsExpression(keys, ExpressionKey.Relaxed);
                        }
                    }
                }
                catch (Exception)
                {
                    // Capability absence is reported with fixed issue codes below.
                }
            }

            for (int meshIndex = 0; meshIndex < meshes.Count; meshIndex += 1)
            {
                Mesh mesh = meshes[meshIndex];
                int blendShapeLimit = Math.Min(
                    mesh.blendShapeCount,
                    MaximumBlendShapesPerMesh);
                for (int shapeIndex = 0; shapeIndex < blendShapeLimit; shapeIndex += 1)
                {
                    string shape = mesh.GetBlendShapeName(shapeIndex);
                    support.LipSync |= MatchesAlias(shape, MouthBlendShapeAliases);
                    support.Blink |= MatchesAlias(shape, BlinkBlendShapeAliases);
                    support.Happy |= MatchesAlias(shape, HappyBlendShapeAliases);
                    support.Sad |= MatchesAlias(shape, SadBlendShapeAliases);
                    support.Angry |= MatchesAlias(shape, AngryBlendShapeAliases);
                    support.Surprised |= MatchesAlias(
                        shape,
                        SurprisedBlendShapeAliases);
                    support.Relaxed |= MatchesAlias(shape, RelaxedBlendShapeAliases);
                }
            }
            return support;
        }

        private static bool SupportsVrmLookAt(
            Vrm10Instance instance,
            IReadOnlyList<ExpressionKey> keys,
            bool leftEye,
            bool rightEye)
        {
            if (instance?.Vrm?.LookAt == null || instance.Runtime?.LookAt == null)
            {
                return false;
            }
            if (instance.Vrm.LookAt.LookAtType == LookAtType.bone)
            {
                return leftEye && rightEye;
            }
            return keys != null &&
                ContainsExpression(keys, ExpressionKey.LookLeft) &&
                ContainsExpression(keys, ExpressionKey.LookRight) &&
                ContainsExpression(keys, ExpressionKey.LookUp) &&
                ContainsExpression(keys, ExpressionKey.LookDown);
        }

        private static bool ContainsExpression(
            IReadOnlyList<ExpressionKey> keys,
            ExpressionKey expected)
        {
            for (int index = 0; index < keys.Count; index += 1)
            {
                if (keys[index].Equals(expected))
                {
                    return true;
                }
            }
            return false;
        }

        private static bool MatchesAlias(string value, string[] aliases)
        {
            if (string.IsNullOrEmpty(value))
            {
                return false;
            }
            for (int index = 0; index < aliases.Length; index += 1)
            {
                if (string.Equals(value, aliases[index], StringComparison.OrdinalIgnoreCase))
                {
                    return true;
                }
            }
            return false;
        }

        private static bool IsFiniteBounds(Bounds bounds)
        {
            Vector3 center = bounds.center;
            Vector3 size = bounds.size;
            return IsFinite(center.x) && IsFinite(center.y) && IsFinite(center.z) &&
                IsFinite(size.x) && IsFinite(size.y) && IsFinite(size.z) &&
                size.x > 0f && size.y > 0f && size.z > 0f;
        }

        private static bool IsFinite(float value)
        {
            return !float.IsNaN(value) && !float.IsInfinity(value);
        }

        private static int SaturatingIncrement(int value, int maximum)
        {
            return value >= maximum ? maximum : value + 1;
        }

        private static int SaturatingAdd(int value, int addition, int maximum)
        {
            if (addition <= 0 || value >= maximum)
            {
                return value;
            }
            return addition >= maximum - value ? maximum : value + addition;
        }

        private static long SaturatingAdd(long value, long addition, long maximum)
        {
            if (addition <= 0 || value >= maximum)
            {
                return value;
            }
            return addition >= maximum - value ? maximum : value + addition;
        }
    }

    internal sealed class RenderScan
    {
        internal bool Renderable;
        internal int RendererCount;
        internal int SkinnedMeshCount;
        internal int VertexCount;
        internal int TriangleCount;
        internal int MaterialCount;
        internal int TextureCount;
        internal int MaxTextureSize;
        internal long EstimatedTextureBytes;
        internal readonly List<Mesh> Meshes = new();
    }

    internal sealed class ExpressionSupport
    {
        internal bool VrmLookAt;
        internal bool LipSync;
        internal bool Blink;
        internal bool Happy;
        internal bool Sad;
        internal bool Angry;
        internal bool Surprised;
        internal bool Relaxed;
    }
}
