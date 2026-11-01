using System;
using System.Collections;
using System.Collections.Generic;
using Newtonsoft.Json.Linq;
using System.Text.RegularExpressions;
using Maaso.World;
using UnityEngine;

namespace Maaso.Avatar
{
    [Serializable]
    public sealed class AgentSpaceCommand
    {
        public string requestId;
        public string sessionId;
        public float x;
        public float y;
        public bool animated;
        public float viewportTop = float.NaN;
        public float viewportBottom = float.NaN;
    }

    [Serializable]
    public sealed class AgentSpaceResult
    {
        public string method;
        public string requestId;
        public string sessionId;
        public bool ok;
        public string code;
    }

    /// <summary>The selected local avatar and its bundled personal room.
    /// No map transfer, multiplayer membership or remote entity owns this view.</summary>
    [DisallowMultipleComponent]
    public sealed class AgentSpaceController : MonoBehaviour
    {
        private UnityAvatarCommandReceiver receiver;
        private PersistentWorldMapController room;
        private PersonalSpaceNavigation navigation;
        private WorldOwnerAvatarLease owner;
        private WorldCameraDirector cameraDirector;
        private Camera spaceCamera;
        private string sessionId;
        private readonly HashSet<string> retiredSessions = new();
        private readonly Queue<string> retiredOrder = new();
        private List<Vector3> route;
        private int waypoint;
        private bool entering, leaving, returningAlongFloor;
        private Transform enteredAvatar;
        private Vector2 homeViewport;
        private int transitionGeneration;
        private float privateReturnStartedAt;
        private readonly List<PendingReceipt> entryReceipts = new();
        private readonly List<PendingReceipt> exitReceipts = new();
        private readonly List<PendingReceipt> frameReceipts = new();

        private sealed class PendingReceipt
        {
            public AgentSpaceResult Result;
            public Action<AgentSpaceResult> Report;
            public bool Completed;
        }

        public bool IsActive => owner != null && owner.IsBound && !string.IsNullOrEmpty(sessionId);
        public bool IsReturningHome => leaving;
        public Transform ActiveAvatar => owner?.AvatarRoot;
        public string SessionId => sessionId ?? string.Empty;
        private bool HasSession => !string.IsNullOrEmpty(sessionId);

        // JsonUtility supplies CLR defaults for absent fields. Establish omission
        // explicitly so legacy packets cannot accidentally acquire a viewport.
        public static AgentSpaceCommand ParseCommand(string json)
        {
            var command = new AgentSpaceCommand();
            try
            {
                JObject document = JObject.Parse(json);
                command = JsonUtility.FromJson<AgentSpaceCommand>(json) ?? command;
                command.viewportTop = ReadViewport(document, "viewportTop");
                command.viewportBottom = ReadViewport(document, "viewportBottom");
                if (document.TryGetValue("animated", out JToken animated) && animated.Type != JTokenType.Boolean)
                    command.requestId = string.Empty;
            }
            catch (Exception) { command.requestId = string.Empty; }
            return command;
        }

        private static float ReadViewport(JObject document, string field)
        {
            if (!document.TryGetValue(field, out JToken value)) return float.NaN;
            if (value.Type is not (JTokenType.Float or JTokenType.Integer)) return float.PositiveInfinity;
            double number = value.Value<double>();
            return double.IsNaN(number) || double.IsInfinity(number) ? float.PositiveInfinity : (float)number;
        }

        public void ExecuteAsync(string method, AgentSpaceCommand command, Action<AgentSpaceResult> report)
        {
            var pending = new PendingReceipt { Result = Result(method, command), Report = report };
            if (!Valid(command)) { Complete(pending, "invalid_request"); return; }
            try
            {
                string code;
                switch (method)
                {
                    case "enterAgentSpace":
                        code = Enter(command, command.animated);
                        if (string.IsNullOrEmpty(code) && entering)
                        { entryReceipts.Add(pending); return; }
                        break;
                    case "leaveAgentSpace":
                        if (command.animated && !HasSession && frameReceipts.Exists(value =>
                                value.Result.method == method && value.Result.sessionId == command.sessionId))
                        {
                            frameReceipts.Add(pending);
                            StartCoroutine(ReportAfterFrame(pending, transitionGeneration));
                            return;
                        }
                        code = Leave(command, command.animated);
                        if (string.IsNullOrEmpty(code) && leaving)
                        { exitReceipts.Add(pending); return; }
                        break;
                    case "requestAgentSpaceMoveAtScreenPoint": code = Move(command); break;
                    default: code = "unsupported_command"; break;
                }
                Complete(pending, code);
            }
            catch (Exception error)
            {
                Debug.LogException(error);
                CancelForReset();
                Complete(pending, "space_renderer_failed");
            }
        }

        private static AgentSpaceResult Result(string method, AgentSpaceCommand command) => new()
        {
            method = method,
            requestId = command?.requestId ?? string.Empty,
            sessionId = command?.sessionId ?? string.Empty,
            code = string.Empty,
        };

        public AgentSpaceResult Execute(string method, AgentSpaceCommand command)
        {
            var result = Result(method, command);
            if (!Valid(command)) { result.code = "invalid_request"; return result; }
            try
            {
                switch (method)
                {
                    case "enterAgentSpace": result.code = Enter(command, false); break;
                    case "leaveAgentSpace": result.code = Leave(command, false); break;
                    case "requestAgentSpaceMoveAtScreenPoint": result.code = Move(command); break;
                    default: result.code = "unsupported_command"; break;
                }
                result.ok = string.IsNullOrEmpty(result.code);
            }
            catch (Exception error)
            {
                Debug.LogException(error);
                if (method == "enterAgentSpace") RestoreHome();
                result.code = "space_renderer_failed";
            }
            return result;
        }

        private string Enter(AgentSpaceCommand command, bool animated)
        {
            string requestedSession = command.sessionId;
            if (retiredSessions.Contains(requestedSession)) return "session_retired";
            if (HasSession) return sessionId == requestedSession && !leaving ? string.Empty : "space_busy";
            receiver = GetComponent<UnityAvatarCommandReceiver>() ??
                FindAnyObjectByType<UnityAvatarCommandReceiver>(FindObjectsInactive.Include);
            room = PersistentWorldMapController.EnsureRuntimeMap();
            navigation = CoastalPrivateWorldContract.FindNavigation(room);
            FrontFullBodyCamera framing = FindSelectedAvatarFraming(receiver?.ActiveAvatarRoot);
            Camera camera = framing?.GetComponent<Camera>();
            if (receiver == null) return "avatar_renderer_unavailable";
            if (room == null) return "personal_room_unavailable";
            if (navigation == null) return "personal_navigation_unavailable";
            if (camera == null || framing == null) return "personal_camera_unavailable";
            if (!receiver.PrepareHomeOwnerForAgentSpace()) return "avatar_presentation_unavailable";
            homeViewport = framing.ViewportSafeArea;
            Transform avatar = receiver.ActiveAvatarRoot;
            if (avatar == null) return "selected_avatar_unavailable";
            if (!navigation.ContainsFoot(avatar.position) &&
                (!room.AlignHomeAvatar(avatar) || !navigation.ContainsFoot(avatar.position)))
                return "avatar_floor_unavailable";
            var anchor = new GameObject("AgentSpaceOwner");
            anchor.transform.SetParent(room.transform, false);
            owner = anchor.AddComponent<WorldOwnerAvatarLease>();
            if (!owner.BindPersonalRoom(receiver, room.HomeAgentAnchor, avatar.position, avatar.rotation))
            { DestroyObject(anchor); owner = null; return "selected_avatar_unavailable"; }
            owner.SetWorldVisible(true);
            sessionId = requestedSession;
            enteredAvatar = avatar;
            transitionGeneration++;
            spaceCamera = camera;
            room.SetWorldActive(true);
            cameraDirector = camera.GetComponent<WorldCameraDirector>() ??
                camera.gameObject.AddComponent<WorldCameraDirector>();
            cameraDirector.BindPrivateRoom(navigation, _ => CancelForReset());
            if (!cameraDirector.EnterWorld(camera, framing, owner.transform, null))
            { RestoreHome(); return "personal_camera_unavailable"; }
            if (HasViewport(command)) framing.SetViewportSafeArea(command.viewportTop, command.viewportBottom);
            if (animated && !cameraDirector.PreparePrivateEntryRoute())
            { RestoreHome(); return "personal_camera_unavailable"; }
            entering = animated;
            if (!animated && !cameraDirector.CompletePrivateEntryImmediately())
            { RestoreHome(); return "personal_camera_unavailable"; }
            return string.Empty;
        }

        private string Leave(AgentSpaceCommand command, bool animated)
        {
            string requestedSession = command.sessionId;
            Retire(requestedSession);
            if (!HasSession)
            {
                if (!animated)
                {
                    foreach (PendingReceipt pending in frameReceipts.ToArray())
                    {
                        if (pending.Result.sessionId != requestedSession) continue;
                        frameReceipts.Remove(pending);
                        Complete(pending, "space_transition_cancelled");
                    }
                }
                return string.Empty;
            }
            if (sessionId != requestedSession) return "session_mismatch";
            if (HasViewport(command)) homeViewport = new Vector2(command.viewportTop, command.viewportBottom);
            FrontFullBodyCamera framing = cameraDirector?.GetComponent<FrontFullBodyCamera>();
            framing?.SetViewportSafeArea(homeViewport.x, homeViewport.y);
            if (!animated)
            {
                CancelReceipts(entryReceipts);
                CancelReceipts(exitReceipts);
                CancelReceipts(frameReceipts);
                transitionGeneration++;
                RestoreHome();
                return string.Empty;
            }
            if (leaving) return string.Empty;
            CancelReceipts(entryReceipts);
            CancelReceipts(frameReceipts);
            entering = false;
            // Retarget the running stride onto the reviewed Home path. An
            // ordinary exit must not cut a half-completed footfall to idle.
            route = null;
            waypoint = 0;
            leaving = true;
            if (owner == null || navigation == null || room?.HomeAgentAnchor == null ||
                !navigation.TryBuildRoute(owner.transform.position, room.HomeAgentAnchor.position,
                    navigation.RouteNodes, out var homeRoute))
            {
                leaving = false;
                StopMovement();
                return "path_blocked";
            }
            route = homeRoute;
            waypoint = 0;
            returningAlongFloor = true;
            privateReturnStartedAt = Time.realtimeSinceStartup;
            BindRouteContinuation();
            return string.Empty;
        }

        private string Move(AgentSpaceCommand command)
        {
            if (!IsActive || sessionId != command.sessionId) return "session_mismatch";
            if (entering || leaving) return "space_busy";
            if (!Finite(command.x) || !Finite(command.y) || command.x < 0 || command.x > 1 || command.y < 0 || command.y > 1)
                return "invalid_screen_point";
            Camera camera = spaceCamera;
            if (camera == null || room?.GroundCollider == null) return "personal_room_unavailable";
            Ray ray = camera.ViewportPointToRay(new Vector3(command.x, 1 - command.y, 0));
            if (!room.GroundCollider.Raycast(ray, out var hit, 200)) return "outside_walkable_floor";
            if (!navigation.TryBuildRoute(owner.transform.position, hit.point, navigation.RouteNodes, out var planned))
                return "path_blocked";
            route = planned;
            waypoint = 0;
            BindRouteContinuation();
            AdvanceRoute();
            return string.Empty;
        }

        private void LateUpdate()
        {
            if (leaving && Time.realtimeSinceStartup - privateReturnStartedAt >= 30f)
            { FailPrivateReturn("personal_camera_unavailable", true); return; }
            if (HasSession && receiver != null &&
                (!receiver.isActiveAndEnabled || receiver.ActiveAvatarRoot != enteredAvatar))
            { CancelForReset(); return; }
            if (entering && cameraDirector?.CurrentPhase == WorldCameraPhase.Active)
            {
                entering = false;
                ReportCompleted(entryReceipts);
            }
            if (leaving && cameraDirector?.CurrentPhase == WorldCameraPhase.Home)
            {
                leaving = false;
                sessionId = null;
                enteredAvatar = null;
                ReportCompleted(exitReceipts);
            }
            AdvanceRoute();
            AdvancePrivateReturn();
        }

        private void AdvanceRoute()
        {
            if (!IsActive || entering || (leaving && !returningAlongFloor) || route == null || waypoint >= route.Count) return;
            // Intermediate corners are route geometry, not destinations at
            // which to settle a complete footfall and restart the gait.
            while (waypoint < route.Count - 1)
            {
                Vector3 arrived = route[waypoint] - owner.transform.position; arrived.y = 0f;
                if (arrived.sqrMagnitude > .0001f) break;
                waypoint++;
            }
            Vector3 target = route[waypoint];
            if (navigation.CrossesBedroomPortal(owner.transform.position, new[] { target }))
            {
                if (navigation.BedroomDoor == null || !navigation.BedroomDoor.RequestOpen())
                { StopMovement(); FailPrivateReturn("path_blocked"); return; }
                if (!navigation.BedroomDoor.IsOpen)
                {
                    owner.ApplyTarget(owner.transform.position, owner.transform.rotation, true);
                    return;
                }
            }
            if (!navigation.SegmentIsClear(owner.transform.position, target))
            { StopMovement(); FailPrivateReturn("path_blocked"); return; }
            bool finalDestination = waypoint == route.Count - 1;
            owner.ApplyRouteTarget(target, owner.transform.rotation, finalDestination);
            Vector3 remaining = target - owner.transform.position;
            remaining.y = 0;
            if (finalDestination && remaining.sqrMagnitude <= .0001f && !owner.IsMoving) waypoint++;
        }

        private void BindRouteContinuation()
        {
            WorldOwnerAvatarLease routeOwner = owner;
            string routeSession = sessionId;
            int generation = transitionGeneration;
            routeOwner?.SetRouteContinuation(() =>
            {
                if (!IsActive || owner != routeOwner || sessionId != routeSession || transitionGeneration != generation ||
                    enteredAvatar != routeOwner.AvatarRoot || route == null || waypoint >= route.Count) return false;
                AdvanceRoute();
                return IsActive && owner == routeOwner && sessionId == routeSession && transitionGeneration == generation &&
                    route != null && waypoint < route.Count;
            });
        }

        private void AdvancePrivateReturn()
        {
            if (returningAlongFloor && Time.realtimeSinceStartup - privateReturnStartedAt > 25f)
            { StopMovement(); FailPrivateReturn("personal_camera_unavailable", true); return; }
            if (!returningAlongFloor || !IsActive || route == null || waypoint < route.Count || owner.IsMoving) return;
            if (!owner.FaceStationaryPersonalHome()) return;
            returningAlongFloor = false;
            int generation = transitionGeneration;
            if (!cameraDirector.BeginPrivateExit(() =>
            {
                if (generation != transitionGeneration || !leaving) return;
                ReleaseCompletedPersonalHomeOwner();
            }))
            {
                FailPrivateReturn("personal_camera_unavailable");
            }
        }

        private void FailPrivateReturn(string code, bool restoreImmediately = false)
        {
            if (!leaving) return;
            leaving = false;
            returningAlongFloor = false;
            var failed = exitReceipts.ToArray();
            exitReceipts.Clear();
            if (restoreImmediately)
            {
                transitionGeneration++;
                RestoreHome();
            }
            foreach (PendingReceipt pending in failed) Complete(pending, code);
        }

        public void SetFraming(string mode) => cameraDirector?.SetPrivateCameraMode(mode);

        private void StopMovement()
        {
            route = null;
            waypoint = 0;
            owner?.SetRouteContinuation(null);
            if (IsActive) owner.ApplyTarget(owner.transform.position, owner.transform.rotation, true);
        }

        private void RestoreHome()
        {
            if (!HasSession && owner == null) return;
            StopMovement();
            entering = false;
            leaving = false;
            returningAlongFloor = false;
            if (HasSession)
                cameraDirector?.GetComponent<FrontFullBodyCamera>()?.SetViewportSafeArea(homeViewport.x, homeViewport.y);
            if (cameraDirector?.CurrentPhase != WorldCameraPhase.Home)
                cameraDirector?.BeginExit(ReleaseHomeOwner);
            cameraDirector?.RestoreHomeImmediately();
            ReleaseHomeOwner();
            sessionId = null;
            enteredAvatar = null;
        }

        private void ReleaseHomeOwner()
            =>ReleaseHomeOwnerCore(false);

        private void ReleaseCompletedPersonalHomeOwner()
            =>ReleaseHomeOwnerCore(true);

        private void ReleaseHomeOwnerCore(bool preserveReturnedPresentation)
        {
            Transform returnedAvatar=null;
            if (owner != null)
            {
                Transform candidate=owner.AvatarRoot;
                if(preserveReturnedPresentation && owner.CompletePersonalReturnToHome())
                    returnedAvatar=candidate;
                else
                    owner.CompleteReturnToHome();
                DestroyObject(owner.gameObject);
                owner = null;
            }
            if(returnedAvatar==null || room==null || !room.AdoptReturnedHomeAvatar(returnedAvatar))
                room?.SetWorldActive(false);
            cameraDirector?.BindPrivateRoom(null, null);
            navigation = null;
            spaceCamera = null;
        }

        public void CancelForReset()
        {
            if (!HasSession && entryReceipts.Count == 0 && exitReceipts.Count == 0 && frameReceipts.Count == 0) return;
            if (HasSession) Retire(sessionId);
            transitionGeneration++;
            CancelReceipts(entryReceipts);
            CancelReceipts(exitReceipts);
            CancelReceipts(frameReceipts);
            RestoreHome();
        }

        private void ReportCompleted(List<PendingReceipt> receipts)
        {
            var completed = receipts.ToArray();
            receipts.Clear();
            foreach (PendingReceipt pending in completed)
            {
                if (!Application.isPlaying || !isActiveAndEnabled)
                { Complete(pending, string.Empty); continue; }
                frameReceipts.Add(pending);
                StartCoroutine(ReportAfterFrame(pending, transitionGeneration));
            }
        }

        private IEnumerator ReportAfterFrame(PendingReceipt pending, int generation)
        {
            yield return new WaitForEndOfFrame();
            frameReceipts.Remove(pending);
            Complete(pending, generation == transitionGeneration ? string.Empty : "space_transition_cancelled");
        }

        private static void CancelReceipts(List<PendingReceipt> receipts)
        {
            var cancelled = receipts.ToArray();
            receipts.Clear();
            foreach (PendingReceipt pending in cancelled) Complete(pending, "space_transition_cancelled");
        }

        private static void Complete(PendingReceipt pending, string code)
        {
            if (pending.Completed) return;
            pending.Completed = true;
            pending.Result.code = code ?? string.Empty;
            pending.Result.ok = string.IsNullOrEmpty(code);
            pending.Report?.Invoke(pending.Result);
        }

        private static bool HasViewport(AgentSpaceCommand command) => !float.IsNaN(command.viewportTop);
        private static bool Valid(AgentSpaceCommand command) => command != null &&
            Identifier(command.requestId) && Identifier(command.sessionId) &&
            ((float.IsNaN(command.viewportTop) && float.IsNaN(command.viewportBottom)) ||
             (Finite(command.viewportTop) && Finite(command.viewportBottom) &&
              command.viewportTop >= 0f && command.viewportTop <= .45f &&
              command.viewportBottom >= 0f && command.viewportBottom <= .45f));

        private static FrontFullBodyCamera FindSelectedAvatarFraming(Transform avatar)
        {
            if (avatar == null) return null;
            Camera main = Camera.main;
            FrontFullBodyCamera primary = main?.GetComponent<FrontFullBodyCamera>();
            if (primary != null && primary.TargetRoot == avatar) return primary;
            foreach (FrontFullBodyCamera candidate in FindObjectsByType<FrontFullBodyCamera>(FindObjectsInactive.Exclude))
            {
                Camera camera = candidate.GetComponent<Camera>();
                if (candidate.TargetRoot == avatar && camera != null && camera.isActiveAndEnabled)
                    return candidate;
            }
            return null;
        }

        private void Retire(string value)
        {
            if (!retiredSessions.Add(value)) return;
            retiredOrder.Enqueue(value);
            while (retiredOrder.Count > 32) retiredSessions.Remove(retiredOrder.Dequeue());
        }

        private void OnApplicationPause(bool paused) { if (paused) CancelForReset(); }
        private void OnDisable() => CancelForReset();
        private static bool Identifier(string value) => value != null && Regex.IsMatch(value, "\\A[A-Za-z0-9._:-]{1,128}\\z");
        private static bool Finite(float value) => !float.IsNaN(value) && !float.IsInfinity(value);
        private static void DestroyObject(GameObject value)
        { if (Application.isPlaying) Destroy(value); else DestroyImmediate(value); }
    }
}
