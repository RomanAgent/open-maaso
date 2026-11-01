#if UNITY_EDITOR
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using UniVRM10;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.SceneManagement;
using Object = UnityEngine.Object;

namespace Maaso.Avatar.Editor
{
    /// <summary>Replaces only the bound avatar in the authored scene; never rebuilds its world.</summary>
    public static class MaasoDefaultAvatarInstaller
    {
        [MenuItem("Maaso/Avatar/Install Default VRM In Existing Scene", false, 6)]
        public static void InstallDefault()
        {
            if (Enumerable.Range(0, SceneManager.sceneCount)
                .Select(SceneManager.GetSceneAt).Any(scene => scene.isDirty))
                throw new InvalidOperationException("Save open scene changes before installing the avatar.");

            string modelPath = MaasoDefaultAvatarSceneBuilder.DefaultVrmPath;
            if (!File.Exists(modelPath)) throw new FileNotFoundException("Default VRM is missing.", modelPath);
            AssetDatabase.ImportAsset(modelPath,
                ImportAssetOptions.ForceSynchronousImport | ImportAssetOptions.ForceUpdate);
            Scene scene = EditorSceneManager.OpenScene(
                MaasoDefaultAvatarSceneBuilder.ScenePath, OpenSceneMode.Single);
            InstallInScene(scene, modelPath);
            if (!EditorSceneManager.SaveScene(scene))
                throw new IOException("Could not save the existing Companion scene.");
            AssetDatabase.SaveAssets();
            Debug.Log("[MaasoAvatar] Installed " + modelPath + " without rebuilding the scene.");
        }

        public static void RunFromCommandLine() => InstallDefault();

        // Public for an editor regression test. This operation does not save a scene or alter build settings.
        public static GameObject InstallInScene(Scene scene, string modelPath)
        {
            if (!scene.IsValid() || !scene.isLoaded)
                throw new ArgumentException("A loaded scene is required.", nameof(scene));
            if (EditorApplication.isPlayingOrWillChangePlaymode)
                throw new InvalidOperationException("Install an avatar only outside Play mode.");
            GameObject asset = AssetDatabase.LoadAssetAtPath<GameObject>(modelPath);
            ValidateAvatar(asset);
            UnityAvatarCommandReceiver[] receivers = ComponentsInScene<UnityAvatarCommandReceiver>(scene);
            if (receivers.Length != 1)
                throw new InvalidOperationException("Expected exactly one avatar command receiver.");
            var serializedReceiver = new SerializedObject(receivers[0]);
            Transform previous = serializedReceiver.FindProperty("avatarRoot")
                ?.objectReferenceValue as Transform;
            if (previous == null || previous.gameObject.scene != scene)
                throw new InvalidOperationException("Receiver has no scene-owned avatar root.");
            if (receivers[0].transform.IsChildOf(previous))
                throw new InvalidOperationException("The receiver must remain outside the replaced avatar.");
            Vrm10Instance previousVrm = ValidateAvatar(previous.gameObject);
            Vrm10Instance[] sceneVrms = ComponentsInScene<Vrm10Instance>(scene);
            if (sceneVrms.Length != 1 || sceneVrms[0] != previousVrm)
                throw new InvalidOperationException("Expected only the bound VRM in the Companion scene.");
            Animator previousAnimator = previous.GetComponentInChildren<Animator>(true);
            if (previousAnimator.runtimeAnimatorController == null)
                throw new InvalidOperationException("The current avatar has no action controller to preserve.");

            GameObject replacement = PrefabUtility.InstantiatePrefab(asset, scene) as GameObject;
            if (replacement == null) throw new InvalidOperationException("Could not instantiate the VRM prefab.");
            var applied = new List<ReferenceChange>();
            try
            {
                replacement.name = previous.name;
                replacement.transform.SetParent(previous.parent, false);
                replacement.transform.localPosition = previous.localPosition;
                replacement.transform.localRotation = previous.localRotation;
                replacement.transform.localScale = previous.localScale;
                replacement.transform.SetSiblingIndex(previous.GetSiblingIndex());
                replacement.SetActive(previous.gameObject.activeSelf);
                foreach (Transform child in replacement.GetComponentsInChildren<Transform>(true))
                {
                    child.gameObject.layer = previous.gameObject.layer;
                    PrefabUtility.RecordPrefabInstancePropertyModifications(child.gameObject);
                }
                Vrm10Instance nextVrm = ValidateAvatar(replacement);
                Animator nextAnimator = replacement.GetComponentInChildren<Animator>(true);
                nextAnimator.runtimeAnimatorController = previousAnimator.runtimeAnimatorController;
                nextAnimator.applyRootMotion = previousAnimator.applyRootMotion;
                nextAnimator.cullingMode = previousAnimator.cullingMode;
                nextAnimator.updateMode = previousAnimator.updateMode;
                nextVrm.LookAtTarget = previousVrm.LookAtTarget;
                nextVrm.LookAtTargetType = previousVrm.LookAtTargetType;

                Dictionary<Object, Object> mappings = BuildMappings(previous, replacement.transform,
                    previousVrm, nextVrm, previousAnimator, nextAnimator);
                if (nextVrm.LookAtTarget != null && nextVrm.LookAtTarget.IsChildOf(previous))
                {
                    if (!mappings.TryGetValue(nextVrm.LookAtTarget, out Object target))
                        throw new InvalidOperationException("Unmapped avatar LookAt target.");
                    nextVrm.LookAtTarget = (Transform)target;
                }
                // Resolve every external reference before changing any of them. An unknown binding
                // is a failed install, not permission to silently erase a camera or world reference.
                List<ReferenceChange> changes = PlanReferenceChanges(scene, previous,
                    replacement.transform, mappings);
                foreach (ReferenceChange change in changes)
                {
                    WriteReference(change, change.After);
                    applied.Add(change);
                }
                PrefabUtility.RecordPrefabInstancePropertyModifications(replacement.transform);
                PrefabUtility.RecordPrefabInstancePropertyModifications(nextAnimator);
                PrefabUtility.RecordPrefabInstancePropertyModifications(nextVrm);
                Object.DestroyImmediate(previous.gameObject);
                EditorSceneManager.MarkSceneDirty(scene);
                return replacement;
            }
            catch
            {
                foreach (ReferenceChange change in applied) WriteReference(change, change.Before);
                Object.DestroyImmediate(replacement);
                throw;
            }
        }

        private static Vrm10Instance ValidateAvatar(GameObject root)
        {
            if (root == null) throw new InvalidOperationException("The model is not an imported VRM prefab.");
            Vrm10Instance[] vrms = root.GetComponentsInChildren<Vrm10Instance>(true);
            Animator animator = root.GetComponentInChildren<Animator>(true);
            bool renderable = root.GetComponentsInChildren<SkinnedMeshRenderer>(true)
                .Any(renderer => renderer.sharedMesh != null && renderer.sharedMesh.vertexCount > 0);
            if (vrms.Length != 1 || animator == null || animator.avatar == null ||
                !animator.avatar.isHuman || !animator.avatar.isValid ||
                animator.GetBoneTransform(HumanBodyBones.Head) == null || !renderable)
                throw new InvalidOperationException("The default avatar must be a renderable VRM 1.0 Humanoid.");
            return vrms[0];
        }

        private static Dictionary<Object, Object> BuildMappings(Transform previous, Transform next,
            Vrm10Instance previousVrm, Vrm10Instance nextVrm, Animator previousAnimator, Animator nextAnimator)
        {
            var mappings = new Dictionary<Object, Object>
            {
                [previous] = next, [previous.gameObject] = next.gameObject,
                [previousVrm] = nextVrm, [previousAnimator] = nextAnimator,
            };
            for (int index = 0; index < (int)HumanBodyBones.LastBone; index++)
            {
                Transform oldBone = previousAnimator.GetBoneTransform((HumanBodyBones)index);
                Transform newBone = nextAnimator.GetBoneTransform((HumanBodyBones)index);
                if (oldBone == null || newBone == null) continue;
                mappings[oldBone] = newBone;
                mappings[oldBone.gameObject] = newBone.gameObject;
            }
            return mappings;
        }

        private static List<ReferenceChange> PlanReferenceChanges(Scene scene, Transform previous,
            Transform next, Dictionary<Object, Object> mappings)
        {
            var changes = new List<ReferenceChange>();
            foreach (Component component in ComponentsInScene<Component>(scene))
            {
                // Parent/child links are managed by SetParent/DestroyImmediate, not serialized bindings.
                if (component == null || component is Transform || component.transform.IsChildOf(previous) ||
                    component.transform.IsChildOf(next)) continue;
                var serialized = new SerializedObject(component);
                SerializedProperty property = serialized.GetIterator();
                while (property.Next(true))
                {
                    if (property.propertyType != SerializedPropertyType.ObjectReference) continue;
                    Object before = property.objectReferenceValue;
                    Transform referenced = before is Component referencedComponent
                        ? referencedComponent.transform : (before as GameObject)?.transform;
                    if (referenced == null || !referenced.IsChildOf(previous)) continue;
                    if (!mappings.TryGetValue(before, out Object after))
                        throw new InvalidOperationException("Unmapped avatar reference: " +
                            component.name + "." + property.propertyPath + " -> " + before.name);
                    changes.Add(new ReferenceChange(component, property.propertyPath, before, after));
                }
            }
            return changes;
        }

        private static void WriteReference(ReferenceChange change, Object value)
        {
            var serialized = new SerializedObject(change.Component);
            serialized.FindProperty(change.Path).objectReferenceValue = value;
            serialized.ApplyModifiedPropertiesWithoutUndo();
            PrefabUtility.RecordPrefabInstancePropertyModifications(change.Component);
        }

        private static T[] ComponentsInScene<T>(Scene scene) where T : Component =>
            scene.GetRootGameObjects().SelectMany(root => root.GetComponentsInChildren<T>(true)).ToArray();

        private sealed class ReferenceChange
        {
            public readonly Component Component;
            public readonly string Path;
            public readonly Object Before;
            public readonly Object After;
            public ReferenceChange(Component component, string path, Object before, Object after)
            { Component = component; Path = path; Before = before; After = after; }
        }
    }
}
#endif
