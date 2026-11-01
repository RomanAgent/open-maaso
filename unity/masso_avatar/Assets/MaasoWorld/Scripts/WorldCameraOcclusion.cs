using System;
using System.Collections.Generic;
using UnityEngine;

namespace Maaso.World
{
    /// <summary>
    /// Reveals the world owner through the room's solid shell. The art has no
    /// wall colliders, so sight lines are tested in each mesh's local space.
    /// Material overrides exist only while this camera renders.
    /// </summary>
    [DisallowMultipleComponent]
    [ExecuteAlways]
    [RequireComponent(typeof(Camera))]
    public sealed class WorldCameraOcclusion : MonoBehaviour
    {
        public const string ShaderResourceName = "MaasoWorldOcclusion";
        private const float HiddenOpacity = 0.08f;
        private const float FadeOutSeconds = 0.18f;
        private const float FadeInSeconds = 0.30f;
        private const float ClearDelaySeconds = 0.15f;
        private const float RefreshSeconds = 0.5f;
        private static readonly int OpacityId = Shader.PropertyToID("_OcclusionOpacity");
        private static readonly HumanBodyBones[] OcclusionBones =
        {
            HumanBodyBones.Head, HumanBodyBones.Chest, HumanBodyBones.Hips,
            HumanBodyBones.LeftLowerLeg, HumanBodyBones.RightLowerLeg,
            HumanBodyBones.LeftFoot, HumanBodyBones.RightFoot,
            HumanBodyBones.LeftToes, HumanBodyBones.RightToes,
        };
        private static readonly string[] MaterialKeywords =
        {
            "_NORMALMAP", "_METALLICGLOSSMAP", "_EMISSION",
            "_SMOOTHNESS_TEXTURE_ALBEDO_CHANNEL_A",
            "_SPECULARHIGHLIGHTS_OFF", "_GLOSSYREFLECTIONS_OFF",
        };

        private readonly List<MeshRenderer> candidates = new();
        private readonly List<MeshRenderer> collected = new();
        private readonly List<Renderer> subjectRenderers = new();
        private readonly List<Transform> subjectBones = new();
        private readonly List<Material> surfaceMaterials = new();
        private readonly Dictionary<Renderer, FadeState> states = new();
        private readonly List<Renderer> expired = new();
        private readonly Vector3[] samplePoints = new Vector3[15 + OcclusionBones.Length];
        private int samplePointCount;
        private Camera targetCamera;
        private WorldCameraDirector director;
        private PersistentWorldMapController map;
        private Transform environmentRoot;
        private Transform subjectRoot;
        private float nextRefreshAt;
        private Shader fadeShader;

        private sealed class FadeState
        {
            public Material[] Originals;
            public Material[] Faded;
            public float Opacity = 1f;
            public float LastBlockedAt;
            public bool Applied;
        }

        public void Configure(WorldCameraDirector source)
        {
            ResetOcclusion();
            director = source;
            targetCamera = GetComponent<Camera>();
            map = FindAnyObjectByType<PersistentWorldMapController>();
            enabled = true;
        }

        private void OnPreCull()
        {
            PrepareFrame(Time.realtimeSinceStartup, Time.unscaledDeltaTime);
        }

        private void OnPostRender() => RestoreRenderers();
        private void OnDisable() => ResetOcclusion();
        private void OnDestroy() => ResetOcclusion();

        private void PrepareFrame(float now, float deltaTime)
        {
            // Also recovers from an interrupted render that missed OnPostRender.
            RestoreRenderers();
            Transform owner = director != null ? director.OcclusionTarget : null;
            if (!isActiveAndEnabled || owner == null || targetCamera == null)
            {
                ResetOcclusion();
                return;
            }
            WorldOwnerAvatarLease lease = owner.GetComponent<WorldOwnerAvatarLease>();
            Transform subject = lease != null ? lease.AvatarRoot : owner;
            if (subject == null || !subject.gameObject.activeInHierarchy)
            {
                ResetOcclusion();
                return;
            }
            if (map == null)
            {
                map = FindAnyObjectByType<PersistentWorldMapController>();
            }
            if (map == null)
            {
                ResetOcclusion();
                return;
            }
            bool changed = environmentRoot != map.PersistentEnvironmentRoot ||
                subjectRoot != subject;
            if (changed)
            {
                ResetOcclusion();
                environmentRoot = map.PersistentEnvironmentRoot;
                subjectRoot = subject;
            }
            if (changed || now >= nextRefreshAt)
            {
                candidates.Clear();
                CollectSurfaces(environmentRoot);
                subjectRenderers.Clear();
                subject.GetComponentsInChildren(false, subjectRenderers);
                CollectSubjectBones(subject);
                nextRefreshAt = now + RefreshSeconds;
            }
            if (!TryGetSubjectBounds(out Bounds bounds) ||
                targetCamera.WorldToViewportPoint(bounds.center).z <= targetCamera.nearClipPlane)
            {
                ResetOcclusion();
                return;
            }
            BuildSamplePoints(bounds);
            fadeShader ??= Resources.Load<Shader>(ShaderResourceName);
            if (fadeShader == null || !fadeShader.isSupported)
            {
                ResetOcclusion();
                return;
            }

            foreach (MeshRenderer candidate in candidates)
            {
                if (!CanRender(candidate) || !HasOpaqueStandardMaterials(candidate) ||
                    candidate.transform.IsChildOf(subject))
                {
                    continue;
                }
                // An overhead room view is a cutaway: remove its roof even
                // near the window where the owner's sight line misses it.
                // Otherwise half the space stays covered by an opaque slab.
                bool roofCutaway = IsRoomCeiling(candidate.name) &&
                    targetCamera.transform.position.y > candidate.bounds.min.y;
                bool blocked = roofCutaway;
                for (int index = 0; index < samplePointCount; index++)
                {
                    Vector3 point = samplePoints[index];
                    Ray ray = targetCamera.ViewportPointToRay(
                        targetCamera.WorldToViewportPoint(point));
                    if (IntersectsSightLine(candidate, ray.origin, point))
                    {
                        blocked = true;
                        break;
                    }
                }
                if (!blocked) continue;
                MarkBlocked(candidate, now);
                if (candidate.name == "PS_Bed_Platform" || candidate.name == "PS_Bed_Cushion")
                {
                    // The window bench's base and thin seat form one solid
                    // occluder. Treat them together so the seat cannot remain
                    // between sample rows after the base has revealed the legs.
                    // The separate pillow keeps its own sight-line decision.
                    foreach (MeshRenderer part in candidates)
                    {
                        if (part != null && part.transform.parent == candidate.transform.parent &&
                            (part.name == "PS_Bed_Platform" || part.name == "PS_Bed_Cushion") &&
                            CanRender(part) && HasOpaqueStandardMaterials(part))
                            MarkBlocked(part, now);
                    }
                }
            }

            expired.Clear();
            foreach (KeyValuePair<Renderer, FadeState> pair in states)
            {
                Renderer renderer = pair.Key;
                FadeState state = pair.Value;
                if (!CanRender(renderer) || !HasOpaqueStandardMaterials(renderer) ||
                    !candidates.Contains(renderer as MeshRenderer))
                {
                    ReleaseMaterials(state);
                    expired.Add(renderer);
                    continue;
                }
                bool blocked = now - state.LastBlockedAt <= ClearDelaySeconds;
                bool roofCutaway = IsRoomCeiling(renderer.name) &&
                    targetCamera.transform.position.y > renderer.bounds.min.y;
                float destination = blocked ? roofCutaway ? 0f : HiddenOpacity : 1f;
                float seconds = blocked ? FadeOutSeconds : FadeInSeconds;
                state.Opacity = Mathf.MoveTowards(state.Opacity, destination,
                    Mathf.Max(0f, deltaTime) * (1f - HiddenOpacity) / seconds);
                if (state.Opacity >= 1f)
                {
                    ReleaseMaterials(state);
                    expired.Add(renderer);
                    continue;
                }
                ApplyMaterials(renderer, state);
            }
            foreach (Renderer renderer in expired) states.Remove(renderer);
        }

        private void MarkBlocked(Renderer renderer, float now)
        {
            if (!states.TryGetValue(renderer, out FadeState state))
            {
                state = new FadeState();
                states.Add(renderer, state);
            }
            state.LastBlockedAt = now;
        }

        private void CollectSurfaces(Transform root)
        {
            if (root == null) return;
            collected.Clear();
            root.GetComponentsInChildren(true, collected);
            foreach (MeshRenderer renderer in collected)
            {
                // The compressed view outside the window is real geometry too:
                // reveal every intervening layer, not just the indoor shell.
                // Window frames and skirting are joined hollow meshes whose
                // bounds would give false hits through their empty openings.
                string meshName = renderer.name;
                if (IsCoastalRoomSurface(meshName) ||
                    meshName == "PS_Ceiling" || meshName == "PS_Wall_Left" ||
                    meshName == "PS_Wall_Right" || meshName == "PS_Wall_Back" ||
                    meshName == "PS_Window_Sill" ||
                    meshName.StartsWith("PS_Window_Wall_", StringComparison.Ordinal) ||
                    meshName.StartsWith("PS_Exterior_", StringComparison.Ordinal) ||
                    meshName.StartsWith("PS_Curtain_", StringComparison.Ordinal) ||
                    meshName.StartsWith("PS_Plant_Window", StringComparison.Ordinal) ||
                    meshName.StartsWith("PS_Plant_Tall_", StringComparison.Ordinal) ||
                    meshName.StartsWith("PS_Plant_Olive_", StringComparison.Ordinal) ||
                    meshName.StartsWith("PS_Armchair_", StringComparison.Ordinal) ||
                    meshName.StartsWith("PS_Sofa_", StringComparison.Ordinal) ||
                    meshName.StartsWith("PS_FloorLamp_", StringComparison.Ordinal) ||
                    meshName.StartsWith("PS_Bed_", StringComparison.Ordinal) ||
                    meshName.StartsWith("PS_Window_Handle", StringComparison.Ordinal))
                {
                    if (!candidates.Contains(renderer)) candidates.Add(renderer);
                }
            }
        }

        private static bool IsRoomCeiling(string meshName) =>
            meshName == "PS_Ceiling" || meshName == "V2_Ceiling" ||
            meshName == "V2_Ceiling_Baked" || meshName == "V4_BedroomCeiling";

        private static bool IsCoastalRoomSurface(string meshName)
        {
            // Export keeps walls and window profiles separate. Furniture is
            // consolidated per item, never into a room-wide bounding box.
            // Ground, rugs, skirting and optically clear panes stay untouched.
            return IsRoomCeiling(meshName) ||
                meshName == "V2_West_Wall" || meshName == "V2_East_Wall" ||
                meshName == "V2_South_Door_Lintel" ||
                meshName == "V2_Distant_Ocean" ||
                meshName == "V2_Window_Stone_Sill" ||
                meshName == "V2_Concealed_Curtain_Track" ||
                meshName.StartsWith("V2_South_Wall_", StringComparison.Ordinal) ||
                meshName.StartsWith("V2_Entrance_", StringComparison.Ordinal) ||
                meshName.StartsWith("V2_Window_Vertical_Profile", StringComparison.Ordinal) ||
                meshName.StartsWith("V2_Window_Horizontal_Profile", StringComparison.Ordinal) ||
                meshName.StartsWith("V2_Sheer_Curtain_", StringComparison.Ordinal) ||
                meshName.StartsWith("V2_Linen_Drape_", StringComparison.Ordinal) ||
                meshName.StartsWith("V2_Olive_", StringComparison.Ordinal) ||
                meshName.StartsWith("V2_Strelitzia_", StringComparison.Ordinal) ||
                meshName.StartsWith("V2_Sofa", StringComparison.Ordinal) ||
                meshName.StartsWith("V2_Lounge", StringComparison.Ordinal) ||
                meshName.StartsWith("V2_CoffeeTable", StringComparison.Ordinal) ||
                meshName.StartsWith("V2_Reading", StringComparison.Ordinal) ||
                meshName.StartsWith("V2_Sideboard", StringComparison.Ordinal) ||
                meshName.StartsWith("V2_WorkDesk", StringComparison.Ordinal) ||
                meshName.StartsWith("V2_WorkChair", StringComparison.Ordinal) ||
                meshName.StartsWith("V2_Bookshelf", StringComparison.Ordinal) ||
                // The current room consolidates furniture into V4 meshes.
                // Their authored labels changed; the same sight-line rule
                // must still reveal the selected person through these items.
                meshName.StartsWith("V4_Olive_", StringComparison.Ordinal) ||
                meshName.StartsWith("V4_Strelitzia_", StringComparison.Ordinal) ||
                meshName.StartsWith("V4_Sofa_", StringComparison.Ordinal) ||
                meshName.StartsWith("V4_Lounge_", StringComparison.Ordinal) ||
                meshName.StartsWith("V4_CoffeeTable_", StringComparison.Ordinal) ||
                meshName.StartsWith("V4_WorkDesk_", StringComparison.Ordinal) ||
                meshName.StartsWith("V4_WorkChair_", StringComparison.Ordinal) ||
                meshName.StartsWith("V4_Sideboard_", StringComparison.Ordinal) ||
                meshName.StartsWith("V4_Bookshelf_", StringComparison.Ordinal) ||
                meshName.StartsWith("V4_BedFrame_", StringComparison.Ordinal) ||
                meshName.StartsWith("V4_BedMattress_", StringComparison.Ordinal) ||
                meshName.StartsWith("V4_BedBedding_", StringComparison.Ordinal) ||
                meshName.StartsWith("V4_BedPillows_", StringComparison.Ordinal) ||
                meshName.StartsWith("V4_BedroomDetails_", StringComparison.Ordinal) ||
                meshName.StartsWith("V4_OriginalWestWall", StringComparison.Ordinal) ||
                meshName == "V4_BedroomSouthWall" || meshName == "V4_BedroomWestWall" ||
                meshName == "V4_BedroomPortalLintel" || meshName == "V4_BedroomWindowSill" ||
                meshName.StartsWith("V4_EntryLeaf", StringComparison.Ordinal) ||
                meshName.StartsWith("V4_EntryFrame", StringComparison.Ordinal);
        }

        private bool CanRender(Renderer renderer) => renderer != null &&
            renderer.enabled && !renderer.forceRenderingOff &&
            renderer.gameObject.activeInHierarchy &&
            (targetCamera.cullingMask & (1 << renderer.gameObject.layer)) != 0;

        private bool HasOpaqueStandardMaterials(Renderer renderer)
        {
            surfaceMaterials.Clear();
            renderer.GetSharedMaterials(surfaceMaterials);
            if (surfaceMaterials.Count == 0) return false;
            foreach (Material material in surfaceMaterials)
            {
                if (material == null || material.shader == null ||
                    (material.shader.name != "Standard" && material.shader.name != "Maaso/CoastalBakedRadiance") ||
                    !material.HasProperty("_Mode") || material.GetFloat("_Mode") != 0f)
                {
                    return false;
                }
            }
            return true;
        }

        private bool TryGetSubjectBounds(out Bounds bounds)
        {
            bounds = default;
            bool found = false;
            foreach (Renderer renderer in subjectRenderers)
            {
                if (!CanRender(renderer) ||
                    !(renderer is SkinnedMeshRenderer || renderer is MeshRenderer)) continue;
                Bounds item = renderer.bounds;
                if (!IsFinite(item.center) || !IsFinite(item.extents)) continue;
                if (!found) bounds = item;
                else bounds.Encapsulate(item);
                found = true;
            }
            return found;
        }

        private void CollectSubjectBones(Transform subject)
        {
            subjectBones.Clear();
            Animator animator = subject.GetComponentInChildren<Animator>(false);
            if (animator == null || animator.avatar == null ||
                !animator.avatar.isValid || !animator.avatar.isHuman) return;
            foreach (HumanBodyBones id in OcclusionBones)
            {
                Transform bone = animator.GetBoneTransform(id);
                if (bone != null) subjectBones.Add(bone);
            }
        }

        private void BuildSamplePoints(Bounds bounds)
        {
            // Sample the projected silhouette, including the camera-facing feet.
            // A world-Y grid through the body's centre misses a nearby sill that
            // hides the front of the legs when looking down from the world camera.
            Vector2 minimum = new(float.PositiveInfinity, float.PositiveInfinity);
            Vector2 maximum = new(float.NegativeInfinity, float.NegativeInfinity);
            for (int corner = 0; corner < 8; corner++)
            {
                Vector3 point = bounds.center + Vector3.Scale(bounds.extents,
                    new Vector3((corner & 1) == 0 ? -1f : 1f,
                        (corner & 2) == 0 ? -1f : 1f, (corner & 4) == 0 ? -1f : 1f));
                Vector3 viewport = targetCamera.WorldToViewportPoint(point);
                if (viewport.z <= targetCamera.nearClipPlane) continue;
                minimum = Vector2.Min(minimum, new Vector2(viewport.x, viewport.y));
                maximum = Vector2.Max(maximum, new Vector2(viewport.x, viewport.y));
            }
            for (int row = 0; row < 5; row++)
            {
                for (int column = 0; column < 3; column++)
                {
                    Vector3 viewport = new(
                        Mathf.Lerp(minimum.x, maximum.x, 0.14f + column * 0.36f),
                        Mathf.Lerp(minimum.y, maximum.y, 0.08f + row * 0.21f), 0f);
                    Vector3 point = bounds.center;
                    if (IsFinite(viewport))
                    {
                        Ray ray = targetCamera.ViewportPointToRay(viewport);
                        if (bounds.IntersectRay(ray, out float distance))
                        {
                            // IntersectsSightLine keeps a 5 cm end clearance.
                            point = ray.GetPoint(distance + 0.08f);
                        }
                    }
                    samplePoints[row * 3 + column] = point;
                }
            }
            // Skinned bounds include empty animation margins. An occluder can
            // sit inside those bounds but in front of an actual leg. Supplement
            // the silhouette with live joint positions instead of extending all
            // rays through the body or baking the skinned mesh every frame.
            samplePointCount = 15;
            foreach (Transform bone in subjectBones)
            {
                if (bone == null || !bone.gameObject.activeInHierarchy) continue;
                Vector3 point = bone.position;
                if (IsFinite(point)) samplePoints[samplePointCount++] = point;
            }
        }

        public static bool IntersectsSightLine(Renderer renderer, Vector3 origin, Vector3 target)
        {
            if (renderer == null || !IsFinite(origin) || !IsFinite(target)) return false;
            Vector3 direction = target - origin;
            float distance = direction.magnitude;
            if (distance <= 0.05f) return false;
            // Stop before the body: geometry behind or touching the target must
            // not disappear. InverseTransformPoint handles rotated/scaled slabs.
            Vector3 end = target - direction / distance * 0.05f;
            Matrix4x4 inverse = renderer.localToWorldMatrix.inverse;
            Vector3 localOrigin = inverse.MultiplyPoint3x4(origin);
            Vector3 localDirection = inverse.MultiplyPoint3x4(end) - localOrigin;
            float length = localDirection.magnitude;
            if (length <= 0.00001f || !IsFinite(localDirection)) return false;
            Bounds localBounds = renderer.localBounds;
            localBounds.Expand(0.01f);
            return localBounds.IntersectRay(new Ray(localOrigin, localDirection / length),
                out float entry) && entry <= length;
        }

        private void ApplyMaterials(Renderer renderer, FadeState state)
        {
            Material[] current = renderer.sharedMaterials;
            if (!SameMaterials(current, state.Originals))
            {
                ReleaseMaterials(state);
                state.Originals = current;
                state.Faded = new Material[current.Length];
                for (int index = 0; index < current.Length; index++)
                {
                    Material original = current[index];
                    if (original == null) continue;
                    // Baked room radiance owns its no-fog cutaway pass. Other
                    // Standard environments keep the existing lit fade shader.
                    Shader targetShader = original.shader.name == "Maaso/CoastalBakedRadiance"
                        ? original.shader : fadeShader;
                    var faded = new Material(targetShader)
                    {
                        hideFlags = HideFlags.HideAndDontSave,
                        name = original.name + " (World Occlusion)",
                    };
                    faded.CopyPropertiesFromMaterial(original);
                    faded.shader = targetShader;
                    faded.shaderKeywords = Array.Empty<string>();
                    foreach (string keyword in MaterialKeywords)
                    {
                        if (original.IsKeywordEnabled(keyword)) faded.EnableKeyword(keyword);
                    }
                    // The room shell is opaque Standard art, never glass or an avatar.
                    faded.renderQueue = 2000;
                    state.Faded[index] = faded;
                }
            }
            foreach (Material material in state.Faded)
            {
                if (material != null) material.SetFloat(OpacityId, state.Opacity);
            }
            renderer.sharedMaterials = state.Faded;
            state.Applied = true;
        }

        private void RestoreRenderers()
        {
            foreach (KeyValuePair<Renderer, FadeState> pair in states)
            {
                if (!pair.Value.Applied) continue;
                // Do not overwrite another system that changed the material
                // during this camera's render callbacks.
                if (pair.Key != null && SameMaterials(pair.Key.sharedMaterials, pair.Value.Faded))
                {
                    pair.Key.sharedMaterials = pair.Value.Originals;
                }
                pair.Value.Applied = false;
            }
        }

        private void ResetOcclusion()
        {
            RestoreRenderers();
            foreach (FadeState state in states.Values) ReleaseMaterials(state);
            states.Clear();
            candidates.Clear();
            subjectRenderers.Clear();
            subjectBones.Clear();
            samplePointCount = 0;
            environmentRoot = subjectRoot = null;
            nextRefreshAt = 0f;
        }

        private static bool SameMaterials(Material[] left, Material[] right)
        {
            if (left == null || right == null || left.Length != right.Length) return false;
            for (int index = 0; index < left.Length; index++)
            {
                if (left[index] != right[index]) return false;
            }
            return true;
        }

        private static void ReleaseMaterials(FadeState state)
        {
            if (state.Faded != null)
            {
                foreach (Material material in state.Faded)
                {
                    if (material == null) continue;
                    if (Application.isPlaying) Destroy(material);
                    else DestroyImmediate(material);
                }
            }
            state.Originals = state.Faded = null;
        }

        private static bool IsFinite(Vector3 value) =>
            float.IsFinite(value.x) && float.IsFinite(value.y) && float.IsFinite(value.z);
    }
}
