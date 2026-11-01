#if UNITY_EDITOR
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
using UnityEditor;
using UnityEngine;

namespace Maaso.Avatar.Editor
{
    /// <summary>Calibrates source leg and foot references without changing the FBX animation.</summary>
    public static class MaasoHumanoidReferencePose
    {
        private const float ReferenceToleranceDegrees = 0.1f;

        public static bool EnsureStraightLegReference(string fbxPath)
        {
            var importer = AssetImporter.GetAtPath(fbxPath) as ModelImporter;
            if (importer == null || importer.animationType != ModelImporterAnimationType.Human)
            {
                throw Failure(fbxPath, "Expected an imported Humanoid FBX.");
            }

            GameObject instance = CreateReferenceInstance(fbxPath, out Animator animator,
                out HumanDescription description, out Dictionary<string, Transform> transforms);
            float beforeError;
            Quaternion neutralLeft;
            Quaternion neutralRight;
            try
            {
                ReadNeutralFootRotations(fbxPath, description, out neutralLeft, out neutralRight);
                beforeError = ReferenceAxisError(animator, instance.transform, neutralLeft,
                    neutralRight, fbxPath);
                if (beforeError <= ReferenceToleranceDegrees)
                {
                    return false;
                }

                Transform hips = RequiredBone(animator, HumanBodyBones.Hips, fbxPath);
                Transform leftFoot = RequiredBone(animator, HumanBodyBones.LeftFoot, fbxPath);
                Transform rightFoot = RequiredBone(animator, HumanBodyBones.RightFoot, fbxPath);
                Vector3 up = instance.transform.up;
                float initialFootHeight = Mathf.Min(Vector3.Dot(leftFoot.position, up),
                    Vector3.Dot(rightFoot.position, up));

                StraightenLeg(animator, true, up, instance.transform.rotation * neutralLeft, fbxPath);
                StraightenLeg(animator, false, up, instance.transform.rotation * neutralRight, fbxPath);
                float correctedFootHeight = Mathf.Min(Vector3.Dot(leftFoot.position, up),
                    Vector3.Dot(rightFoot.position, up));
                hips.position += up * (initialFootHeight - correctedFootHeight);

                SkeletonBone[] skeleton = description.skeleton;
                for (int i = 0; i < skeleton.Length; i++)
                {
                    Transform bone = transforms[skeleton[i].name];
                    skeleton[i].position = bone.localPosition;
                    skeleton[i].rotation = bone.localRotation;
                    skeleton[i].scale = bone.localScale;
                }
                description.skeleton = skeleton;
            }
            finally
            {
                UnityEngine.Object.DestroyImmediate(instance);
            }

            importer.humanDescription = description;
            importer.SaveAndReimport();

            GameObject verified = CreateReferenceInstance(fbxPath, out Animator verifiedAnimator,
                out _, out _);
            float afterError;
            try
            {
                afterError = ReferenceAxisError(verifiedAnimator, verified.transform,
                    neutralLeft, neutralRight, fbxPath);
                if (afterError > ReferenceToleranceDegrees)
                {
                    throw Failure(fbxPath, "Reference legs or feet remain misaligned after reimport: " +
                        afterError.ToString("F3") + " degrees.");
                }
            }
            finally
            {
                UnityEngine.Object.DestroyImmediate(verified);
            }

            Debug.Log("[HumanoidReferencePose] Calibrated " + fbxPath +
                "; reference axis error " + beforeError.ToString("F3") + " -> " +
                afterError.ToString("F3") + " degrees.");
            return true;
        }

        private static GameObject CreateReferenceInstance(string path, out Animator animator,
            out HumanDescription description, out Dictionary<string, Transform> transforms)
        {
            GameObject model = AssetDatabase.LoadAssetAtPath<GameObject>(path);
            if (model == null)
            {
                throw Failure(path, "FBX model is unavailable.");
            }
            GameObject instance = UnityEngine.Object.Instantiate(model);
            instance.name = model.name;
            instance.hideFlags = HideFlags.HideAndDontSave;
            try
            {
                animator = instance.GetComponentInChildren<Animator>(true);
                if (animator == null || animator.avatar == null ||
                    !animator.avatar.isHuman || !animator.avatar.isValid)
                {
                    throw Failure(path, "Source Avatar is missing or invalid.");
                }
                animator.runtimeAnimatorController = null;
                description = animator.avatar.humanDescription;
                if (description.skeleton == null || description.skeleton.Length == 0)
                {
                    throw Failure(path, "Source Avatar has no reference skeleton.");
                }

                var groups = instance.GetComponentsInChildren<Transform>(true)
                    .GroupBy(bone => bone.name, StringComparer.Ordinal).ToArray();
                var duplicate = groups.FirstOrDefault(group => group.Count() > 1);
                if (duplicate != null)
                {
                    throw Failure(path, "Ambiguous reference bone name: " + duplicate.Key);
                }
                transforms = groups.ToDictionary(group => group.Key, group => group.First(),
                    StringComparer.Ordinal);
                string referenceRoot = description.skeleton[0].name;
                if (!transforms.ContainsKey(referenceRoot))
                {
                    Transform hips = RequiredBone(animator, HumanBodyBones.Hips, path);
                    bool isMappedHumanBone = description.human.Any(bone =>
                        string.Equals(bone.boneName, referenceRoot, StringComparison.Ordinal));
                    if (isMappedHumanBone || hips.parent != instance.transform)
                    {
                        throw Failure(path, "Cannot resolve the reference skeleton root: " + referenceRoot);
                    }
                    // Unity's reference skeleton starts with a model-root entry.
                    // Existing imports may retain its generated '(Clone)' name.
                    transforms.Add(referenceRoot, instance.transform);
                    Debug.Log("[HumanoidReferencePose] " + path + ": reference root '" +
                        referenceRoot + "' maps to model root '" + instance.name + "'.");
                }
                foreach (SkeletonBone bone in description.skeleton)
                {
                    if (!transforms.TryGetValue(bone.name, out Transform target))
                    {
                        throw Failure(path, "Reference skeleton bone is missing: " + bone.name);
                    }
                    if (!IsFinite(bone.position) || !IsFinite(bone.scale) ||
                        !IsFinite(new Vector3(bone.rotation.x, bone.rotation.y, bone.rotation.z)) ||
                        float.IsNaN(bone.rotation.w) || float.IsInfinity(bone.rotation.w))
                    {
                        throw Failure(path, "Reference bone has non-finite values: " + bone.name);
                    }
                    target.SetLocalPositionAndRotation(bone.position, bone.rotation);
                    target.localScale = bone.scale;
                }
                return instance;
            }
            catch
            {
                UnityEngine.Object.DestroyImmediate(instance);
                throw;
            }
        }

        private static float ReferenceAxisError(Animator animator, Transform root,
            Quaternion neutralLeft, Quaternion neutralRight, string path)
        {
            float error = 0f;
            Vector3 up = root.up;
            foreach (bool left in new[] { true, false })
            {
                GetLeg(animator, left, path, out Transform thigh, out Transform knee,
                    out Transform foot);
                error = Mathf.Max(error, Vector3.Angle(knee.position - thigh.position, -up));
                error = Mathf.Max(error, Vector3.Angle(foot.position - knee.position, -up));
                Quaternion neutral = left ? neutralLeft : neutralRight;
                error = Mathf.Max(error, Quaternion.Angle(foot.rotation, root.rotation * neutral));
            }
            return error;
        }

        private static void StraightenLeg(Animator animator, bool left, Vector3 up,
            Quaternion neutralFootRotation, string path)
        {
            GetLeg(animator, left, path, out Transform thigh, out Transform knee,
                out Transform foot);
            thigh.rotation = Quaternion.FromToRotation(knee.position - thigh.position, -up) *
                thigh.rotation;
            knee.rotation = Quaternion.FromToRotation(foot.position - knee.position, -up) *
                knee.rotation;
            // A Humanoid import can use animation frame zero as its reference.
            // Restore the static model's foot basis, preserving ankle-to-toe geometry.
            foot.rotation = neutralFootRotation;
        }

        private static void ReadNeutralFootRotations(string path, HumanDescription description,
            out Quaternion left, out Quaternion right)
        {
            string folder = "Assets/__MaasoNeutralFoot_" + Guid.NewGuid().ToString("N");
            string temporaryPath = folder + "/" + Path.GetFileName(path);
            GameObject instance = null;
            try
            {
                AssetDatabase.CreateFolder("Assets", Path.GetFileName(folder));
                File.Copy(path, temporaryPath);
                // Preserve axis/unit import settings while assigning a distinct asset identity.
                string metadata = File.ReadAllText(path + ".meta");
                if (!Regex.IsMatch(metadata, @"(?m)^guid: [a-f0-9]{32}$"))
                {
                    throw Failure(path, "Source importer metadata has no asset GUID.");
                }
                File.WriteAllText(temporaryPath + ".meta", Regex.Replace(metadata,
                    @"(?m)^guid: [a-f0-9]{32}$", "guid: " + Guid.NewGuid().ToString("N")));
                AssetDatabase.ImportAsset(temporaryPath, ImportAssetOptions.ForceSynchronousImport);
                var importer = AssetImporter.GetAtPath(temporaryPath) as ModelImporter;
                if (importer == null)
                {
                    throw Failure(path, "Could not import the temporary static model.");
                }
                importer.animationType = ModelImporterAnimationType.None;
                importer.avatarSetup = ModelImporterAvatarSetup.NoAvatar;
                importer.importAnimation = false;
                importer.optimizeGameObjects = false;
                importer.SaveAndReimport();

                GameObject model = AssetDatabase.LoadAssetAtPath<GameObject>(temporaryPath);
                if (model == null)
                {
                    throw Failure(path, "Temporary static model is unavailable.");
                }
                instance = UnityEngine.Object.Instantiate(model);
                instance.hideFlags = HideFlags.HideAndDontSave;
                var groups = instance.GetComponentsInChildren<Transform>(true)
                    .GroupBy(bone => bone.name, StringComparer.Ordinal).ToArray();
                if (groups.Any(group => group.Count() != 1))
                {
                    throw Failure(path, "Temporary static model has ambiguous bone names.");
                }
                var bones = groups.ToDictionary(group => group.Key, group => group.First(),
                    StringComparer.Ordinal);
                var rotations = new Quaternion[2];
                for (int side = 0; side < rotations.Length; side++)
                {
                    string humanName = side == 0 ? "LeftFoot" : "RightFoot";
                    HumanBone[] mapping = description.human.Where(bone =>
                        bone.humanName == humanName).ToArray();
                    if (mapping.Length != 1 || !bones.TryGetValue(mapping[0].boneName,
                        out Transform foot))
                    {
                        throw Failure(path, "Static model is missing the mapped " + humanName + ".");
                    }
                    Quaternion rotation = Quaternion.Inverse(instance.transform.rotation) * foot.rotation;
                    if (!IsFinite(new Vector3(rotation.x, rotation.y, rotation.z)) ||
                        float.IsNaN(rotation.w) || float.IsInfinity(rotation.w))
                    {
                        throw Failure(path, "Static foot orientation is non-finite: " + humanName);
                    }
                    rotations[side] = rotation;
                }
                left = rotations[0];
                right = rotations[1];
            }
            finally
            {
                if (instance != null)
                {
                    UnityEngine.Object.DestroyImmediate(instance);
                }
                if (AssetDatabase.IsValidFolder(folder) && !AssetDatabase.DeleteAsset(folder))
                {
                    throw Failure(path, "Could not remove temporary static model: " + folder);
                }
            }
        }

        private static void GetLeg(Animator animator, bool left, string path,
            out Transform thigh, out Transform knee, out Transform foot)
        {
            Transform hips = RequiredBone(animator, HumanBodyBones.Hips, path);
            thigh = RequiredBone(animator, left ? HumanBodyBones.LeftUpperLeg : HumanBodyBones.RightUpperLeg, path);
            knee = RequiredBone(animator, left ? HumanBodyBones.LeftLowerLeg : HumanBodyBones.RightLowerLeg, path);
            foot = RequiredBone(animator, left ? HumanBodyBones.LeftFoot : HumanBodyBones.RightFoot, path);
            if (!thigh.IsChildOf(hips) || !knee.IsChildOf(thigh) || !foot.IsChildOf(knee))
            {
                throw Failure(path, (left ? "Left" : "Right") + " leg hierarchy is invalid.");
            }
            Vector3 upper = knee.position - thigh.position;
            Vector3 lower = foot.position - knee.position;
            if (!IsFinite(upper) || !IsFinite(lower) ||
                upper.sqrMagnitude < 0.00000001f || lower.sqrMagnitude < 0.00000001f)
            {
                throw Failure(path, (left ? "Left" : "Right") + " leg has an invalid segment length.");
            }
        }

        private static Transform RequiredBone(Animator animator, HumanBodyBones bone, string path)
        {
            Transform result = animator.GetBoneTransform(bone);
            if (result == null)
            {
                throw Failure(path, "Required Humanoid bone is missing: " + bone);
            }
            return result;
        }

        private static bool IsFinite(Vector3 value)
        {
            return !float.IsNaN(value.x) && !float.IsInfinity(value.x) &&
                !float.IsNaN(value.y) && !float.IsInfinity(value.y) &&
                !float.IsNaN(value.z) && !float.IsInfinity(value.z);
        }

        private static InvalidOperationException Failure(string path, string reason)
        {
            return new InvalidOperationException("[HumanoidReferencePose] " + path + ": " + reason);
        }
    }
}
#endif
