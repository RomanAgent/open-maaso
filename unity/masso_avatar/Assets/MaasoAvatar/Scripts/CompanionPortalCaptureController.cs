using System;
using System.Collections;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using UnityEngine;
using UnityEngine.Rendering;

namespace Maaso.Avatar
{
    [DisallowMultipleComponent]
    public sealed class CompanionPortalCaptureController : MonoBehaviour
    {
        public const string BridgeObjectName = "Maaso Avatar Portal";
        private const int RuntimePortalLayer = 31;
        private const string DesktopHighProfile = "desktopHigh";
#if UNITY_STANDALONE || UNITY_EDITOR
        private const int MaximumSceneWidth = 3840;
        private const int MaximumSceneHeight = 2160;
#else
        private const int MaximumSceneWidth = 1080;
        private const int MaximumSceneHeight = 1600;
#endif

        private readonly Dictionary<Transform, int> originalLayers = new();
        private readonly List<Transform> avatarTransforms = new(128);
        private readonly List<Renderer> avatarRenderers = new(32);
        private UnityAvatarCommandReceiver receiver;
        private UnityWorldLightingController companionLighting;
        private Transform activeAvatarRoot;
        private Camera sourceCamera;
        private Camera portalCamera;
        private GameObject portalCameraObject;
        private RenderTexture targetTexture;
        private CommandBuffer renderThreadCommands;
        private int sourceCameraCullingMask;
        private bool includeWorld;
        private RenderTexture sourceCameraTargetTexture;
        private float sourceCameraAspect;
        private bool sourceCameraEnabled;
        private Coroutine sceneSubmissionCoroutine;
        private int sceneRenderedFrame = -1;
        private int portalLayer = -1;
        private int generation;
        private float minimumFrameIntervalSeconds;
        private double lastSubmittedAtSeconds = double.NegativeInfinity;
        private bool didReportRenderedFrame;
        private bool didReportSubmitFailure;

        public bool IsAcquired => generation > 0 && portalCamera != null;
        public Transform CapturedAvatarRoot => activeAvatarRoot;
        public RenderTexture TargetTexture => targetTexture;

        [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.AfterSceneLoad)]
        private static void Bootstrap()
        {
            CompanionPortalCaptureController existing =
                FindFirstObjectByType<CompanionPortalCaptureController>();
            if (existing != null)
            {
                DontDestroyOnLoad(existing.gameObject);
                return;
            }

            var bridgeObject = new GameObject(BridgeObjectName);
            bridgeObject.AddComponent<CompanionPortalCaptureController>();
            DontDestroyOnLoad(bridgeObject);
        }

        public void OnAvatarPortalCommand(string json)
        {
            if (string.IsNullOrWhiteSpace(json))
            {
                return;
            }

            int commandGeneration = 0;
            try
            {
                PortalCommand command = JsonUtility.FromJson<PortalCommand>(json);
                if (command == null || string.IsNullOrWhiteSpace(command.method))
                {
                    return;
                }
                commandGeneration = command.generation;
                ReportState("unityCommand", commandGeneration);

                switch (command.method)
                {
                    case "acquire":
                        AcquirePresentation(command.generation, command.profile, command.targetFps,
                            command.includeWorld, command.viewportWidth, command.viewportHeight);
                        break;
                    case "suspend":
                        Suspend(command.generation);
                        break;
                    case "resume":
                        Resume(command.generation);
                        break;
                    case "release":
                        Release(command.generation);
                        break;
                }
            }
            catch (Exception exception)
            {
                Debug.LogError($"[AvatarPortal] command failed: {exception.Message}");
                ReportState("unityCommandFailed", commandGeneration);
                Release(0);
            }
        }

        public void Acquire(int nextGeneration, string profile, int targetFps = 0)
        {
            AcquirePresentation(nextGeneration, profile, targetFps, false, 0, 0);
        }

        private void AcquirePresentation(int nextGeneration, string profile, int targetFps,
            bool captureWorld, int viewportWidth, int viewportHeight)
        {
            if (nextGeneration <= 0)
            {
                throw new ArgumentOutOfRangeException(
                    nameof(nextGeneration),
                    "Avatar portal generation must be positive.");
            }

            if (captureWorld && (viewportWidth < 64 || viewportWidth > MaximumSceneWidth ||
                viewportHeight < 64 || viewportHeight > MaximumSceneHeight))
                throw new ArgumentOutOfRangeException(nameof(viewportWidth),
                    $"World capture requires a bounded 64..{MaximumSceneWidth} by 64..{MaximumSceneHeight} viewport.");
            if (!captureWorld && (viewportWidth != 0 || viewportHeight != 0))
                throw new ArgumentException("Avatar-only capture uses its profile dimensions.");

            Release(0);
            includeWorld = captureWorld;
            portalLayer = LayerMask.NameToLayer("AvatarPortal");
            if (portalLayer < 0)
            {
                portalLayer = RuntimePortalLayer;
            }

            receiver = FindFirstObjectByType<UnityAvatarCommandReceiver>();
            if (receiver == null || (!includeWorld && receiver.IsAvatarLeasedToWorld))
            {
                throw new InvalidOperationException(
                    "The active Avatar is unavailable for Feed presentation.");
            }
            activeAvatarRoot = receiver.ActiveAvatarRoot;
            if (activeAvatarRoot == null && !includeWorld)
            {
                throw new InvalidOperationException("The active Avatar root is unavailable.");
            }

            sourceCamera = Camera.main;
            if (sourceCamera == null && includeWorld)
            {
                // Camera.main skips disabled cameras. A suspended Home camera
                // still owns its tag and must be resumable by this acquisition.
                GameObject sourceHost = GameObject.FindWithTag("MainCamera");
                if (sourceHost != null) sourceCamera = sourceHost.GetComponent<Camera>();
            }
            if (sourceCamera == null)
            {
                throw new InvalidOperationException("Avatar portal requires the main Camera.");
            }

            ResolveProfile(
                profile,
                out int width,
                out int height,
                out int profileFramesPerSecond);
            if (includeWorld)
            {
                width = viewportWidth;
                height = viewportHeight;
            }
            int framesPerSecond = ResolveTargetFps(
                targetFps,
                profileFramesPerSecond);
            generation = nextGeneration;
            sourceCameraCullingMask = sourceCamera.cullingMask;
            if (includeWorld)
            {
                // Render the real Home/World camera, including its image effects
                // and room occlusion. A copied camera would omit those components.
                sourceCameraTargetTexture = sourceCamera.targetTexture;
                sourceCameraAspect = sourceCamera.aspect;
                sourceCameraEnabled = sourceCamera.enabled;
                portalCamera = sourceCamera;
                sourceCamera.aspect = (float)width / height;
                sourceCamera.enabled = true;
            }
            else
            {
                ApplyPortalLayer(activeAvatarRoot);
                sourceCamera.cullingMask &= ~(1 << portalLayer);
                portalCameraObject = new GameObject("Maaso Avatar Portal Camera");
                portalCamera = portalCameraObject.AddComponent<Camera>();
                portalCamera.CopyFrom(sourceCamera);
                portalCamera.clearFlags = CameraClearFlags.SolidColor;
                portalCamera.backgroundColor = new Color(0f, 0f, 0f, 0f);
                portalCamera.cullingMask = 1 << portalLayer;
                portalCamera.depth = sourceCamera.depth - 2f;
                portalCamera.allowHDR = false;
                portalCamera.allowMSAA = false;
                portalCamera.useOcclusionCulling = false;
            }

            targetTexture = new RenderTexture(
                width,
                height,
                24,
                RenderTextureFormat.ARGB32,
                RenderTextureReadWrite.sRGB)
            {
                name = "Maaso Avatar Portal RenderTexture",
                useMipMap = false,
                autoGenerateMips = false,
                antiAliasing = 1,
            };
            targetTexture.Create();
            portalCamera.targetTexture = targetTexture;
#if UNITY_STANDALONE_OSX || UNITY_EDITOR
            // Mac scene capture leaves an explicit aspect on the source camera.
            // Its avatar-only copy must project into this portrait texture.
            if (!includeWorld) portalCamera.aspect = (float)width / height;
#endif
            renderThreadCommands = new CommandBuffer
            {
                name = "Maaso Avatar Portal Texture Submission",
            };
            minimumFrameIntervalSeconds = 1f / framesPerSecond;
            lastSubmittedAtSeconds = double.NegativeInfinity;
            didReportRenderedFrame = false;
            didReportSubmitFailure = false;
            UpdateCameraFraming();
            Camera.onPostRender += HandleCameraPostRender;
            if (includeWorld && Application.isPlaying)
                sceneSubmissionCoroutine = StartCoroutine(SubmitSceneFramesAfterRendering());
#if UNITY_STANDALONE_OSX && !UNITY_EDITOR
            if (!includeWorld) EnableCompanionLighting();
#endif
            ReportState("unityAcquired", generation);
        }

        public void Suspend(int requestedGeneration)
        {
            if (!MatchesGeneration(requestedGeneration))
            {
                return;
            }
            if (portalCamera != null)
            {
                portalCamera.enabled = false;
                sceneRenderedFrame = -1;
            }
        }

        public void Resume(int requestedGeneration)
        {
            if (!MatchesGeneration(requestedGeneration) || receiver == null ||
                (!includeWorld && receiver.IsAvatarLeasedToWorld))
            {
                return;
            }
            if (portalCamera != null)
            {
                portalCamera.enabled = true;
            }
        }

        public void Release(int requestedGeneration)
        {
            if (requestedGeneration > 0 && !MatchesGeneration(requestedGeneration))
            {
                return;
            }

#if UNITY_STANDALONE_OSX && !UNITY_EDITOR
            DisableCompanionLighting();
#endif
            Camera.onPostRender -= HandleCameraPostRender;
            if (sceneSubmissionCoroutine != null)
            {
                StopCoroutine(sceneSubmissionCoroutine);
                sceneSubmissionCoroutine = null;
            }
            sceneRenderedFrame = -1;
            if (portalCamera != null)
            {
                portalCamera.targetTexture = includeWorld ? sourceCameraTargetTexture : null;
                if (includeWorld)
                {
                    portalCamera.aspect = sourceCameraAspect;
                    portalCamera.enabled = sourceCameraEnabled;
                }
            }
            if (renderThreadCommands != null)
            {
                renderThreadCommands.Release();
                renderThreadCommands = null;
            }
            if (targetTexture != null)
            {
                targetTexture.Release();
                DestroyObject(targetTexture);
                targetTexture = null;
            }
            if (portalCameraObject != null)
            {
                DestroyObject(portalCameraObject);
                portalCameraObject = null;
            }
            if (sourceCamera != null)
            {
                sourceCamera.cullingMask = sourceCameraCullingMask;
            }
            RestoreOriginalLayers();
            receiver = null;
            activeAvatarRoot = null;
            sourceCamera = null;
            portalCamera = null;
            sourceCameraTargetTexture = null;
            includeWorld = false;
            portalLayer = -1;
            generation = 0;
            lastSubmittedAtSeconds = double.NegativeInfinity;
            didReportRenderedFrame = false;
            didReportSubmitFailure = false;
        }

#if UNITY_STANDALONE_OSX && !UNITY_EDITOR
        private void EnableCompanionLighting()
        {
            companionLighting ??=
                FindFirstObjectByType<UnityWorldLightingController>();
            companionLighting?.EnterCompanionLighting();
        }

        private void DisableCompanionLighting()
        {
            companionLighting?.ExitCompanionLighting();
            companionLighting = null;
        }
#endif

        private void LateUpdate()
        {
            if (!IsAcquired || receiver == null)
            {
                return;
            }
            if (includeWorld)
            {
                activeAvatarRoot = receiver.ActiveAvatarRoot;
                return;
            }
            if (receiver.IsAvatarLeasedToWorld)
            {
                Release(generation);
                return;
            }

            Transform currentRoot = receiver.ActiveAvatarRoot;
            if (currentRoot != activeAvatarRoot)
            {
                RestoreOriginalLayers();
                activeAvatarRoot = currentRoot;
                if (activeAvatarRoot == null)
                {
                    Release(generation);
                    return;
                }
            }
            // Props can be attached after the portal was acquired without
            // replacing the Avatar root (for example, the conversation phone).
            ApplyPortalLayer(activeAvatarRoot);
            UpdateCameraFraming();
        }

        private void HandleCameraPostRender(Camera renderedCamera)
        {
            if (renderedCamera != portalCamera || targetTexture == null ||
                generation <= 0)
            {
                return;
            }
            if (includeWorld)
            {
                // OnRenderImage can still write the final camera target. Only
                // submit this frame after the complete image-effect chain.
                sceneRenderedFrame = Time.frameCount;
                return;
            }
            SubmitRenderedFrame();
        }

        private IEnumerator SubmitSceneFramesAfterRendering()
        {
            var endOfFrame = new WaitForEndOfFrame();
            int capturedGeneration = generation;
            while (IsAcquired && includeWorld && generation == capturedGeneration)
            {
                yield return endOfFrame;
                if (generation != capturedGeneration) yield break;
                SubmitCompletedSceneFrame();
            }
        }

        private void SubmitCompletedSceneFrame()
        {
            if (!IsAcquired || !includeWorld || !portalCamera.enabled ||
                sceneRenderedFrame != Time.frameCount)
                return;
            sceneRenderedFrame = -1;
            SubmitRenderedFrame();
        }

        private void SubmitRenderedFrame()
        {
            double now = Time.realtimeSinceStartupAsDouble;
            if (now - lastSubmittedAtSeconds < minimumFrameIntervalSeconds)
            {
                return;
            }
            lastSubmittedAtSeconds = now;
            if (!didReportRenderedFrame)
            {
                didReportRenderedFrame = true;
                ReportState("unityFrameRendered", generation);
            }
            if (!ScheduleNativeTexture(
                targetTexture.GetNativeTexturePtr(),
                targetTexture.width,
                targetTexture.height,
                generation) && !didReportSubmitFailure)
            {
                didReportSubmitFailure = true;
                ReportState("unitySubmitUnavailable", generation);
            }
        }

        private void ApplyPortalLayer(Transform root)
        {
            if (root == null)
            {
                return;
            }
            root.GetComponentsInChildren(true, avatarTransforms);
            foreach (Transform child in avatarTransforms)
            {
                if (child == null)
                {
                    continue;
                }
                // Repeated scans must retain the authored layer from before
                // this capture lease, including for newly attached children.
                if (!originalLayers.ContainsKey(child))
                {
                    originalLayers.Add(child, child.gameObject.layer);
                }
                if (child.gameObject.layer != portalLayer)
                {
                    child.gameObject.layer = portalLayer;
                }
            }
        }

        private void RestoreOriginalLayers()
        {
            foreach (KeyValuePair<Transform, int> entry in originalLayers)
            {
                if (entry.Key != null)
                {
                    entry.Key.gameObject.layer = entry.Value;
                }
            }
            originalLayers.Clear();
            avatarTransforms.Clear();
            avatarRenderers.Clear();
        }

        private void UpdateCameraFraming()
        {
            if (includeWorld)
            {
                // Respect manual presence choreography and the World camera's
                // disabled Home framing state while adopting the capture aspect.
                sourceCamera.GetComponent<FrontFullBodyCamera>()?.AdvanceFraming(0f);
                return;
            }
            if (portalCamera == null || activeAvatarRoot == null)
            {
                return;
            }
            activeAvatarRoot.GetComponentsInChildren(true, avatarRenderers);
            bool hasBounds = false;
            Bounds bounds = default;
            foreach (Renderer renderer in avatarRenderers)
            {
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
            if (!hasBounds)
            {
                return;
            }

            Vector3 forward = sourceCamera != null
                ? sourceCamera.transform.forward.normalized
                : Vector3.forward;
            Vector3 up = sourceCamera != null
                ? sourceCamera.transform.up.normalized
                : Vector3.up;
            portalCamera.fieldOfView = 28f;
            float verticalExtent = Mathf.Max(bounds.extents.y, 0.25f);
            float distance = verticalExtent /
                Mathf.Tan(portalCamera.fieldOfView * 0.5f * Mathf.Deg2Rad);
            distance *= 1.12f;
            Vector3 center = bounds.center + up * (bounds.extents.y * 0.04f);
            portalCamera.transform.SetPositionAndRotation(
                center - forward * distance,
                Quaternion.LookRotation(forward, up));
            portalCamera.nearClipPlane = Mathf.Max(0.01f, distance - bounds.extents.magnitude * 1.5f);
            portalCamera.farClipPlane = distance + bounds.extents.magnitude * 2.5f;
        }

        private bool MatchesGeneration(int requestedGeneration)
        {
            return generation > 0 &&
                (requestedGeneration <= 0 || requestedGeneration == generation);
        }

        private bool ScheduleNativeTexture(
            IntPtr texture,
            int width,
            int height,
            int activeGeneration)
        {
            if (renderThreadCommands == null || texture == IntPtr.Zero)
            {
                return false;
            }
#if UNITY_IOS && !UNITY_EDITOR
            IntPtr renderEvent = MaasoAvatarPortalGetRenderEventFunc();
            IntPtr eventData = MaasoAvatarPortalScheduleTexture(
                texture,
                width,
                height,
                activeGeneration);
#elif UNITY_ANDROID && !UNITY_EDITOR
            IntPtr renderEvent = MaasoAvatarPortalGetRenderEventFuncAndroid();
            IntPtr eventData = MaasoAvatarPortalScheduleTextureAndroid(
                texture,
                width,
                height,
                activeGeneration);
#elif UNITY_STANDALONE_OSX && !UNITY_EDITOR
            IntPtr renderEvent = MaasoDesktopAvatarPortalGetRenderEventFunc();
            IntPtr eventData = MaasoDesktopAvatarPortalScheduleTexture(
                texture,
                width,
                height,
                activeGeneration);
#else
            IntPtr renderEvent = IntPtr.Zero;
            IntPtr eventData = IntPtr.Zero;
#endif
            if (renderEvent == IntPtr.Zero || eventData == IntPtr.Zero)
            {
                return false;
            }
            renderThreadCommands.Clear();
            renderThreadCommands.IssuePluginEventAndData(renderEvent, 2, eventData);
            Graphics.ExecuteCommandBuffer(renderThreadCommands);
            return true;
        }

        private static void ReportState(string type, int activeGeneration)
        {
            if (string.IsNullOrWhiteSpace(type) || activeGeneration <= 0)
            {
                return;
            }
#if UNITY_IOS && !UNITY_EDITOR
            MaasoAvatarPortalReportEvent(type, activeGeneration);
#elif UNITY_STANDALONE_OSX && !UNITY_EDITOR
            DesktopUnitySidecarBridge.ReportPortalEvent(type, activeGeneration);
#else
            Debug.Log($"[AvatarPortal] {type} generation={activeGeneration}");
#endif
        }

        private static void ResolveProfile(
            string profile,
            out int width,
            out int height,
            out int framesPerSecond)
        {
            if (string.Equals(profile, DesktopHighProfile, StringComparison.Ordinal))
            {
                width = 1024;
                height = 1792;
                framesPerSecond = 30;
                return;
            }
            if (string.Equals(profile, "compactLow", StringComparison.Ordinal))
            {
                width = 240;
                height = 416;
                framesPerSecond = 24;
                return;
            }
            if (string.Equals(profile, "compactBalanced", StringComparison.Ordinal))
            {
                width = 288;
                height = 496;
                framesPerSecond = 30;
                return;
            }
            width = 320;
            height = 560;
            framesPerSecond = 30;
        }

        private static int ResolveTargetFps(int requested, int fallback)
        {
            if (requested == 24 || requested == 30 || requested == 60)
            {
                return requested;
            }
            return fallback;
        }

        private static void DestroyObject(UnityEngine.Object target)
        {
            if (Application.isPlaying)
            {
                Destroy(target);
            }
            else
            {
                DestroyImmediate(target);
            }
        }

        private void OnDestroy()
        {
            Release(0);
        }

#if UNITY_IOS && !UNITY_EDITOR
        [DllImport("__Internal", EntryPoint = "MaasoAvatarPortalScheduleTexture")]
        private static extern IntPtr MaasoAvatarPortalScheduleTexture(
            IntPtr texture,
            int width,
            int height,
            int generation);

        [DllImport("__Internal", EntryPoint = "MaasoAvatarPortalGetRenderEventFunc")]
        private static extern IntPtr MaasoAvatarPortalGetRenderEventFunc();

        [DllImport("__Internal", EntryPoint = "MaasoAvatarPortalReportEvent")]
        private static extern void MaasoAvatarPortalReportEvent(
            string type,
            int generation);
#endif

#if UNITY_ANDROID && !UNITY_EDITOR
        [DllImport("maaso_live_rtc", EntryPoint = "MaasoAvatarPortalScheduleTexture")]
        private static extern IntPtr MaasoAvatarPortalScheduleTextureAndroid(
            IntPtr texture,
            int width,
            int height,
            int generation);

        [DllImport("maaso_live_rtc", EntryPoint = "MaasoAvatarPortalGetRenderEventFunc")]
        private static extern IntPtr MaasoAvatarPortalGetRenderEventFuncAndroid();
#endif

#if UNITY_STANDALONE_OSX && !UNITY_EDITOR
        private const string DesktopPortalLibrary =
            "MaasoDesktopAvatarPortalBridge";

        [DllImport(DesktopPortalLibrary, EntryPoint = "MaasoDesktopAvatarPortalScheduleTexture")]
        private static extern IntPtr MaasoDesktopAvatarPortalScheduleTexture(
            IntPtr texture,
            int width,
            int height,
            int generation);

        [DllImport(DesktopPortalLibrary, EntryPoint = "MaasoDesktopAvatarPortalGetRenderEventFunc")]
        private static extern IntPtr MaasoDesktopAvatarPortalGetRenderEventFunc();
#endif

        [Serializable]
        private sealed class PortalCommand
        {
            public string method;
            public string profile;
            public int generation;
            public int targetFps;
            public bool includeWorld;
            public int viewportWidth;
            public int viewportHeight;
        }
    }
}
