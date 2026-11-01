#if UNITY_EDITOR
using System;
using System.IO;
using System.Linq;
using UnityEditor;
using UnityEditor.Animations;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.SceneManagement;

namespace Maaso.Avatar.Editor
{
    public sealed class MaasoActionPreviewWindow : EditorWindow
    {
        private const string ScenePath =
            MaasoDefaultAvatarSceneBuilder.ScenePath;
        private const string ActionDirectory = "Assets/MaasoAvatar/Animations/Humanoid/Actions";
        private const string ControllerPath = "Assets/MaasoAvatar/Animations/Humanoid/MaasoHumanoid.controller";
        private const string BaseIdleId = "idle";
        private const string MainIdleId = "idle_shrug";

        private ActionClipEntry[] actionClips = Array.Empty<ActionClipEntry>();
        private Vector2 scrollPosition;
        private int selectedClipIndex;
        private float normalizedTime = 0.5f;
        private bool autoPlay;
        private double lastPreviewUpdateTime;
        private string statusMessage = string.Empty;

        [MenuItem("Maaso/Actions/Open Action Preview", false, 0)]
        public static void OpenWindow()
        {
            MaasoActionPreviewWindow window = GetWindow<MaasoActionPreviewWindow>("Maaso Actions");
            window.minSize = new Vector2(430f, 360f);
            window.RefreshClips();
            window.Show();
        }

        [MenuItem("Maaso/Actions/Open Runtime Avatar Scene", false, 1)]
        public static void OpenRuntimeAvatarScene()
        {
            if (!EnsureRuntimeSceneOpen())
            {
                return;
            }

            Animator animator = FindPreviewAnimator();
            if (animator != null)
            {
                Selection.activeGameObject = animator.gameObject;
                FrameAvatar(animator);
            }
        }

        [MenuItem("Maaso/Actions/Stop Action Preview", false, 2)]
        public static void StopActionPreview()
        {
            StopAnimationPreview();
        }

        public static ActionClipEntry[] LoadActionClipsForTests()
        {
            return LoadActionClips();
        }

        public static Animator OpenRuntimeSceneAndFindAnimatorForTests()
        {
            if (!EnsureRuntimeSceneOpen())
            {
                return null;
            }

            return FindPreviewAnimator();
        }

        public static void VerifyActionPreviewForBatch()
        {
            ActionClipEntry[] clips = LoadActionClips();
            if (clips.Length == 0)
            {
                throw new InvalidOperationException("No action clips found under " + ActionDirectory + ".");
            }

            if (clips[0].Id != MainIdleId)
            {
                throw new InvalidOperationException("Main idle clip must be first in the action preview list.");
            }

            if (!EnsureRuntimeSceneOpen())
            {
                throw new InvalidOperationException("Runtime avatar scene was not opened.");
            }

            Animator animator = FindPreviewAnimator();
            if (animator == null)
            {
                throw new InvalidOperationException("No Animator found in " + ScenePath + ".");
            }

            if (animator.runtimeAnimatorController == null)
            {
                throw new InvalidOperationException("Preview Animator has no runtime controller.");
            }

            AnimatorController controller = AssetDatabase.LoadAssetAtPath<AnimatorController>(ControllerPath);
            string defaultStateName = controller?.layers[0].stateMachine.defaultState?.name;
            if (defaultStateName != MainIdleId)
            {
                throw new InvalidOperationException("Animator default idle must be " + MainIdleId + ", got " + defaultStateName + ".");
            }

            UnityAvatarCommandReceiver receiver = UnityEngine.Object.FindAnyObjectByType<UnityAvatarCommandReceiver>();
            var serialized = receiver == null ? null : new SerializedObject(receiver);
            if (serialized?.FindProperty("designedIdleStateName")?.stringValue != MainIdleId)
            {
                throw new InvalidOperationException("UnityAvatarCommandReceiver main idle must be " + MainIdleId + ".");
            }

            Debug.Log("[MaasoActionPreview] Verified " + clips.Length + " action clip(s) for " + animator.name + ".");
        }

        private void OnEnable()
        {
            RefreshClips();
            EditorApplication.update += OnEditorUpdate;
        }

        private void OnDisable()
        {
            EditorApplication.update -= OnEditorUpdate;
            StopAnimationPreview();
        }

        private void OnGUI()
        {
            DrawToolbar();
            EditorGUILayout.Space(6f);

            EditorGUILayout.HelpBox(
                "Preview imported action clips in the real Unity avatar scene. This uses Editor AnimationMode only and does not save scene or controller changes.",
                MessageType.Info);

            if (actionClips.Length == 0)
            {
                EditorGUILayout.HelpBox(
                    "No imported action clips were found. Use Maaso/Actions/Reimport Action FBX Folder first.",
                    MessageType.Warning);
                return;
            }

            DrawPlaybackControls();
            DrawClipList();

            if (!string.IsNullOrWhiteSpace(statusMessage))
            {
                EditorGUILayout.HelpBox(statusMessage, MessageType.None);
            }
        }

        private void DrawToolbar()
        {
            using (new EditorGUILayout.HorizontalScope(EditorStyles.toolbar))
            {
                if (GUILayout.Button("Open Scene", EditorStyles.toolbarButton, GUILayout.Width(86f)))
                {
                    OpenRuntimeAvatarScene();
                }

                if (GUILayout.Button("Refresh", EditorStyles.toolbarButton, GUILayout.Width(70f)))
                {
                    RefreshClips();
                }

                if (GUILayout.Button("Stop", EditorStyles.toolbarButton, GUILayout.Width(54f)))
                {
                    autoPlay = false;
                    StopAnimationPreview();
                }

                GUILayout.FlexibleSpace();
                GUILayout.Label(ActionDirectory, EditorStyles.miniLabel);
            }
        }

        private void DrawPlaybackControls()
        {
            using (new EditorGUILayout.VerticalScope(EditorStyles.helpBox))
            {
                ActionClipEntry selected = actionClips[Mathf.Clamp(selectedClipIndex, 0, actionClips.Length - 1)];
                EditorGUILayout.LabelField(selected.Id, EditorStyles.boldLabel);

                EditorGUI.BeginChangeCheck();
                normalizedTime = EditorGUILayout.Slider("Time", normalizedTime, 0f, 1f);
                autoPlay = EditorGUILayout.Toggle("Auto Play", autoPlay);
                if (EditorGUI.EndChangeCheck())
                {
                    PreviewSelectedClip();
                }

                using (new EditorGUILayout.HorizontalScope())
                {
                    if (GUILayout.Button("Preview Selected", GUILayout.Height(28f)))
                    {
                        PreviewSelectedClip();
                    }

                    if (GUILayout.Button("Select Clip", GUILayout.Width(100f), GUILayout.Height(28f)))
                    {
                        Selection.activeObject = selected.Clip;
                        EditorGUIUtility.PingObject(selected.Clip);
                    }
                }
            }
        }

        private void DrawClipList()
        {
            scrollPosition = EditorGUILayout.BeginScrollView(scrollPosition);
            for (int i = 0; i < actionClips.Length; i++)
            {
                ActionClipEntry entry = actionClips[i];
                using (new EditorGUILayout.HorizontalScope(EditorStyles.helpBox))
                {
                    bool isSelected = i == selectedClipIndex;
                    if (GUILayout.Toggle(isSelected, entry.Id, "Button", GUILayout.MinWidth(180f)))
                    {
                        selectedClipIndex = i;
                    }

                    GUILayout.Label(entry.Clip.length.ToString("0.00") + "s", GUILayout.Width(52f));

                    if (entry.Id == MainIdleId)
                    {
                        GUILayout.Label("main idle", EditorStyles.miniLabel, GUILayout.Width(64f));
                    }
                    else
                    {
                        GUILayout.Space(64f);
                    }

                    if (GUILayout.Button("Preview", GUILayout.Width(70f)))
                    {
                        selectedClipIndex = i;
                        PreviewSelectedClip();
                    }

                    if (GUILayout.Button("Ping", GUILayout.Width(52f)))
                    {
                        Selection.activeObject = entry.Clip;
                        EditorGUIUtility.PingObject(entry.Clip);
                    }
                }
            }

            EditorGUILayout.EndScrollView();
        }

        private void OnEditorUpdate()
        {
            if (!autoPlay || actionClips.Length == 0)
            {
                lastPreviewUpdateTime = EditorApplication.timeSinceStartup;
                return;
            }

            double now = EditorApplication.timeSinceStartup;
            double delta = lastPreviewUpdateTime <= 0d ? 0d : now - lastPreviewUpdateTime;
            lastPreviewUpdateTime = now;

            ActionClipEntry selected = actionClips[Mathf.Clamp(selectedClipIndex, 0, actionClips.Length - 1)];
            float length = Mathf.Max(selected.Clip.length, 1f / 60f);
            normalizedTime = Mathf.Repeat(normalizedTime + (float)(delta / length), 1f);
            PreviewSelectedClip(false);
            Repaint();
        }

        private void RefreshClips()
        {
            actionClips = LoadActionClips();
            selectedClipIndex = Mathf.Clamp(selectedClipIndex, 0, Math.Max(actionClips.Length - 1, 0));
            statusMessage = actionClips.Length == 0
                ? "No action clips found under " + ActionDirectory
                : "Loaded " + actionClips.Length + " action clip(s).";
        }

        private void PreviewSelectedClip(bool updateStatus = true)
        {
            if (actionClips.Length == 0)
            {
                return;
            }

            ActionClipEntry selected = actionClips[Mathf.Clamp(selectedClipIndex, 0, actionClips.Length - 1)];
            try
            {
                Animator animator = PreviewClip(selected, normalizedTime);
                Selection.activeGameObject = animator.gameObject;
                if (updateStatus)
                {
                    statusMessage = "Previewing " + selected.Id + " at " + Mathf.RoundToInt(normalizedTime * 100f) + "%.";
                }
            }
            catch (Exception exception)
            {
                statusMessage = exception.Message;
                Debug.LogException(exception);
            }
        }

        private static Animator PreviewClip(ActionClipEntry entry, float normalizedTime)
        {
            if (!EnsureRuntimeSceneOpen())
            {
                throw new InvalidOperationException("Runtime avatar scene was not opened.");
            }

            Animator animator = FindPreviewAnimator();
            if (animator == null)
            {
                throw new InvalidOperationException("No Animator found in " + ScenePath + ".");
            }

            if (!AnimationMode.InAnimationMode())
            {
                AnimationMode.StartAnimationMode();
            }

            float sampleTime = Mathf.Clamp01(normalizedTime) * Mathf.Max(entry.Clip.length, 1f / 60f);
            AnimationMode.BeginSampling();
            try
            {
                AnimationMode.SampleAnimationClip(animator.gameObject, entry.Clip, sampleTime);
            }
            finally
            {
                AnimationMode.EndSampling();
            }

            FrameAvatar(animator);
            SceneView.RepaintAll();
            return animator;
        }

        private static ActionClipEntry[] LoadActionClips()
        {
            if (!AssetDatabase.IsValidFolder(ActionDirectory))
            {
                return Array.Empty<ActionClipEntry>();
            }

            return AssetDatabase.FindAssets("t:AnimationClip", new[] { ActionDirectory })
                .Select(AssetDatabase.GUIDToAssetPath)
                .Where(path => string.Equals(Path.GetExtension(path), ".anim", StringComparison.OrdinalIgnoreCase))
                .Select(path => new ActionClipEntry(
                    Path.GetFileNameWithoutExtension(path) == "Idle" ? BaseIdleId : Path.GetFileNameWithoutExtension(path),
                    path,
                    AssetDatabase.LoadAssetAtPath<AnimationClip>(path)))
                .Where(entry => entry.Clip != null)
                .OrderBy(entry => entry.Id == MainIdleId ? 0 : 1)
                .ThenBy(entry => entry.Id, StringComparer.Ordinal)
                .ToArray();
        }

        private static bool EnsureRuntimeSceneOpen()
        {
            Scene activeScene = SceneManager.GetActiveScene();
            if (activeScene.path == ScenePath)
            {
                return true;
            }

            if (!Application.isBatchMode && !EditorSceneManager.SaveCurrentModifiedScenesIfUserWantsTo())
            {
                return false;
            }

            EditorSceneManager.OpenScene(ScenePath, OpenSceneMode.Single);
            return true;
        }

        private static Animator FindPreviewAnimator()
        {
            UnityAvatarCommandReceiver receiver =
                UnityEngine.Object.FindAnyObjectByType<UnityAvatarCommandReceiver>();
            Animator activeAnimator = receiver?.ActiveAvatarRoot
                ?.GetComponentInChildren<Animator>(true);
            if (activeAnimator != null)
            {
                return activeAnimator;
            }

            Animator[] animators = UnityEngine.Object.FindObjectsByType<Animator>(
                FindObjectsInactive.Include);
            return animators.FirstOrDefault(animator => animator != null);
        }

        private static void FrameAvatar(Animator animator)
        {
            if (animator == null || SceneView.lastActiveSceneView == null)
            {
                return;
            }

            if (TryGetRendererBounds(animator.transform, out Bounds bounds))
            {
                SceneView.lastActiveSceneView.Frame(bounds, false);
            }
        }

        private static bool TryGetRendererBounds(Transform root, out Bounds bounds)
        {
            bounds = default;
            Renderer[] renderers = root.GetComponentsInChildren<Renderer>(false);
            bool hasBounds = false;

            for (int i = 0; i < renderers.Length; i++)
            {
                Renderer renderer = renderers[i];
                if (renderer == null || !renderer.enabled)
                {
                    continue;
                }

                if (!hasBounds)
                {
                    bounds = renderer.bounds;
                    hasBounds = true;
                }
                else
                {
                    bounds.Encapsulate(renderer.bounds);
                }
            }

            return hasBounds;
        }

        private static void StopAnimationPreview()
        {
            if (AnimationMode.InAnimationMode())
            {
                AnimationMode.StopAnimationMode();
                SceneView.RepaintAll();
            }
        }

        public readonly struct ActionClipEntry
        {
            public ActionClipEntry(string id, string assetPath, AnimationClip clip)
            {
                Id = id;
                AssetPath = assetPath;
                Clip = clip;
            }

            public string Id { get; }
            public string AssetPath { get; }
            public AnimationClip Clip { get; }
        }
    }
}
#endif
