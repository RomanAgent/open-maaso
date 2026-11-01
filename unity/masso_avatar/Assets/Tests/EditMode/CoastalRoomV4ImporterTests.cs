using System;
using System.Linq;
using System.Reflection;
using NUnit.Framework;
using UnityEngine;

public sealed class CoastalRoomV4ImporterTests
{
    private static Type Importer=>Type.GetType("Maaso.World.Editor.CoastalRoomV4Importer, Assembly-CSharp-Editor",true);
    [TestCase("awaiting_color_checked_denoise")]
    [TestCase("raw")]
    public void UnreviewedOrIncompleteAssetCannotPublish(string status)
    {
        var exception=Assert.Throws<TargetInvocationException>(()=>Importer.GetMethod("ParseManifest").Invoke(null,new object[]{"{\"schemaVersion\":4,\"version\":4,\"status\":\""+status+"\"}"}));
        Assert.That(exception.InnerException,Is.TypeOf<System.IO.InvalidDataException>());
    }
    [Test] public void ChangedRoomSourceCannotReuseLegacyAtlasProvenanceSilently()
    {
        string file=System.IO.Path.Combine(Application.dataPath,
            "MaasoWorld/PersonalSpace/CoastalV4/manifest.json");
        var manifest=Newtonsoft.Json.Linq.JObject.Parse(System.IO.File.ReadAllText(file));
        manifest["sourceSha256"]=new string('a',64);
        manifest.Remove("atlasLineage");
        var error=Assert.Throws<TargetInvocationException>(()=>Importer.GetMethod("ParseManifest")
            .Invoke(null,new object[]{manifest.ToString()}));
        Assert.That(error.InnerException,Is.TypeOf<System.IO.InvalidDataException>());
    }
    [TestCase("../old-room.png")]
    [TestCase("/tmp/asset.png")]
    [TestCase("https://example.test/asset.png")]
    public void TextureCannotEscapeThePublishedPackage(string path)
    {
        var exception=Assert.Throws<TargetInvocationException>(()=>Importer.GetMethod("TexturePath").Invoke(null,new object[]{path}));
        Assert.That(exception.InnerException,Is.TypeOf<System.IO.InvalidDataException>());
    }
    [Test] public void BedroomRectangleIsAnExtensionNotAnExpandedSquare()
    {
        var bounds=(Bounds)Importer.GetMethod("Rect").Invoke(null,new object[]{new[]{4.2f,.4f,7.8f,4f}});
        Assert.That(bounds.min.x,Is.EqualTo(4.2f).Within(.001f));Assert.That(bounds.max.x,Is.EqualTo(7.8f).Within(.001f));
        Assert.That(bounds.Contains(new Vector3(6,.05f,-2)),Is.False);
    }
    [Test] public void ACorrectPivotCannotHideDoubleTranslatedDoorMeshGeometry()
    {
        var opening=new Bounds(new Vector3(2.5f,1.185f,4.075f),new Vector3(1.02f,2.37f,.25f));
        var leaf=new Bounds(new Vector3(2.5f,1.175f,4.035f),new Vector3(.97f,2.35f,.06f));
        Importer.GetMethod("ValidateDoorGeometry").Invoke(null,new object[]{leaf,opening,"hinge"});
        leaf.center+=new Vector3(2.985f,0,4.035f);
        var exception=Assert.Throws<TargetInvocationException>(()=>Importer.GetMethod("ValidateDoorGeometry").Invoke(null,new object[]{leaf,opening,"hinge"}));
        Assert.That(exception.InnerException,Is.TypeOf<System.IO.InvalidDataException>());
    }
    [TestCase(false)]
    [TestCase(true)]
    public void BothClosedLeavesMustMatchMeasuredSourceBoundsAndAxisConversion(bool bedroom)
    {
        float[] blender=bedroom?new[]{-4.141f,-2.62f,0,-4.099f,-1.58f,2.29f}:new[]{-2.985f,-4.065f,0,-2.015f,-4.005f,2.35f};
        float[] unity=bedroom?new[]{4.099f,0,1.58f,4.141f,2.29f,2.62f}:new[]{2.015f,0,4.005f,2.985f,2.35f,4.065f};
        var geometry=new Bounds(new Vector3((unity[0]+unity[3])*.5f,(unity[1]+unity[4])*.5f,(unity[2]+unity[5])*.5f),new Vector3(unity[3]-unity[0],unity[4]-unity[1],unity[5]-unity[2]));
        Importer.GetMethod("ValidateClosedLeafBounds").Invoke(null,new object[]{geometry,blender,unity});
        var wrong=geometry;wrong.center+=Vector3.right*.01f;
        Assert.Throws<TargetInvocationException>(()=>Importer.GetMethod("ValidateClosedLeafBounds").Invoke(null,new object[]{wrong,blender,unity}));
        unity[0]+=.005f;
        Assert.Throws<TargetInvocationException>(()=>Importer.GetMethod("ValidateClosedLeafBounds").Invoke(null,new object[]{geometry,blender,unity}));
    }
    [Test] public void LegacyMatTuftsMoveOntoTheExteriorLandingExactlyOnce()
    {
        var root=new GameObject("EntryMatAlignmentTest");
        try
        {
            var mat=GameObject.CreatePrimitive(PrimitiveType.Cube);mat.name="V4_EntryWelcomeMat";
            mat.transform.SetParent(root.transform);mat.transform.position=new Vector3(2.5f,.0215f,4.64f);
            var tufts=GameObject.CreatePrimitive(PrimitiveType.Cube);tufts.name="V4_EntryMatTufts";
            tufts.transform.SetParent(root.transform);tufts.transform.position=new Vector3(.29816f,.04447f,.59298f);
            var align=Importer.GetMethod("AlignEntryMatTufts",BindingFlags.NonPublic|BindingFlags.Static);
            Assert.That(align,Is.Not.Null);
            align.Invoke(null,new object[]{root});
            Vector3 first=tufts.transform.position;
            Assert.That(first.x,Is.EqualTo(2.5f).Within(.001f));
            Assert.That(first.z,Is.EqualTo(4.64f).Within(.001f));
            Assert.That(first.y,Is.EqualTo(.04447f).Within(.001f));
            align.Invoke(null,new object[]{root});
            Assert.That(Vector3.Distance(first,tufts.transform.position),Is.LessThan(.00001f));
        }
        finally{UnityEngine.Object.DestroyImmediate(root);}
    }
}

public sealed class CoastalRoomV4ProvenanceTests
{
    private static Type Importer => Type.GetType(
        "Maaso.World.Editor.CoastalRoomV4Importer, Assembly-CSharp-Editor", true);
    private static string PackageRoot => System.IO.Path.Combine(
        Application.dataPath, "MaasoWorld/PersonalSpace/CoastalV4");
    private static Newtonsoft.Json.Linq.JObject Fixture() =>
        Newtonsoft.Json.Linq.JObject.Parse(System.IO.File.ReadAllText(
            System.IO.Path.Combine(PackageRoot, "manifest.json")));
    private static object Parse(Newtonsoft.Json.Linq.JObject data) =>
        Importer.GetMethod("ParseManifest").Invoke(null, new object[] { data.ToString() });

    [Test]
    public void PublishedPackageKeepsBothSeamlessDoorWallsAndTheAuthoredCoirMat()
    {
        var meshes=Fixture()["meshes"].Children<Newtonsoft.Json.Linq.JObject>().ToArray();
        string GroupOf(string source)=>(string)meshes.Single(mesh=>
            mesh["sourceObjectNames"].Values<string>().Contains(source))["material"];
        Assert.That(GroupOf("V2_South_FacadeInterior"),Is.EqualTo("Baked_South_Wall"));
        Assert.That(GroupOf("V2_South_FacadeExterior"),Is.EqualTo("Baked_South_Wall"));
        Assert.That(GroupOf("V4_OriginalWestWallContinuousMain"),Is.EqualTo("Baked_BedroomWalls"));
        Assert.That(GroupOf("V4_OriginalWestWallContinuousBedroom"),Is.EqualTo("Baked_BedroomWalls"));
        foreach(string source in new[]{"V4_EntryWelcomeMat","V4_EntryMatInset","V4_EntryMatTufts","V4_EntryMatFringe","V4_EntryWelcomeText"})
            Assert.That(GroupOf(source),Is.EqualTo("Baked_BedroomTrim"),source);
        foreach(string source in new[]{"V4_EntryLowerPanelExteriorLeft","V4_EntryLowerPanelExteriorRight"})
            Assert.That(GroupOf(source),Is.EqualTo("PBR_V4_EntryHinge_V4_WhiteDoorPaint"),source);
    }

    [Test]
    public void PublishedRoomGradesOnlyTheCoirGeometry()
    {
        var room=Resources.Load<GameObject>("PersonalSpaceMap");
        Assert.That(room,Is.Not.Null);
        var renderers=room.GetComponentsInChildren<Renderer>(true);
        Renderer Named(string name)=>renderers.Single(renderer=>renderer.name==name);
        var mat=Named("V4_EntryWelcomeMat").sharedMaterial;
        var inset=Named("V4_EntryMatInset").sharedMaterial;
        var letters=Named("V4_EntryWelcomeText").sharedMaterial;
        var reveal=Named("V4_EntryRevealLeft").sharedMaterial;
        Assert.That(mat,Is.SameAs(inset));
        Assert.That(mat,Is.Not.SameAs(letters));
        Assert.That(letters,Is.SameAs(reveal));
        Assert.That(mat.GetColor("_EmissionColor").r,Is.InRange(.73f,.79f));
        Assert.That(mat.GetColor("_EmissionColor").g,Is.InRange(.49f,.55f));
    }
    [Test]
    public void PublishedMatFibresRemainOnTheOutsideMatNotTheHomeFloor()
    {
        var asset=Resources.Load<GameObject>("PersonalSpaceMap");
        Assert.That(asset,Is.Not.Null);
        var room=UnityEngine.Object.Instantiate(asset);
        try
        {
            var renderers=room.GetComponentsInChildren<Renderer>(true);
            Renderer Named(string name)=>renderers.Single(renderer=>renderer.name==name);
            var mat=Named("V4_EntryWelcomeMat").bounds.center;
            var tufts=Named("V4_EntryMatTufts").bounds.center;
            Assert.That(Vector2.Distance(new Vector2(mat.x,mat.z),new Vector2(2.5f,4.64f)),Is.LessThan(.15f));
            Assert.That(Vector2.Distance(new Vector2(mat.x,mat.z),new Vector2(tufts.x,tufts.z)),Is.LessThan(.01f));
            Assert.That(tufts.y,Is.GreaterThan(mat.y));
        }
        finally{UnityEngine.Object.DestroyImmediate(room);}
    }
    private static void Reject(Action action)
    {
        var error = Assert.Throws<TargetInvocationException>(() => action());
        Assert.That(error.InnerException, Is.TypeOf<System.IO.InvalidDataException>());
    }

    [Test]
    public void CurrentPromotedPackageHasCompleteTextureProvenance()
    {
        object manifest = Parse(Fixture());
        Assert.DoesNotThrow(() => Importer.GetMethod("ValidatePackageFiles")
            .Invoke(null, new object[] { manifest, PackageRoot }));
    }

    [TestCase("missing_hash")]
    [TestCase("invalid_hash")]
    [TestCase("missing_table")]
    [TestCase("color_unverified")]
    public void IncompleteTextureReviewCannotReachImport(string mutation)
    {
        var data = Fixture();
        string texture = (string)data["materials"][0]["texture"];
        Assert.That(texture, Is.Not.Null.And.Not.Empty);
        if (mutation == "missing_hash")
            ((Newtonsoft.Json.Linq.JObject)data["artifactHashes"]).Remove(texture);
        else if (mutation == "invalid_hash") data["artifactHashes"][texture] = "not-a-sha";
        else if (mutation == "missing_table") data.Remove("artifactHashes");
        else data["colorTransformVerified"] = false;
        Reject(() => Parse(data));
    }

    [Test]
    public void ChangedTextureBytesFailBeforeAnyUnityImport()
    {
        string temporary = System.IO.Path.Combine(System.IO.Path.GetTempPath(),
            "maaso-v4-hash-test-" + Guid.NewGuid().ToString("N"));
        try
        {
            var data = Fixture();
            var hashes = (Newtonsoft.Json.Linq.JObject)data["artifactHashes"];
            byte[] content = System.Text.Encoding.UTF8.GetBytes("synthetic hash fixture");
            string digest;
            using (var sha = System.Security.Cryptography.SHA256.Create())
                digest = BitConverter.ToString(sha.ComputeHash(content)).Replace("-", "").ToLowerInvariant();
            foreach (var entry in hashes.Properties())
            {
                entry.Value = digest;
                string file = System.IO.Path.Combine(temporary, entry.Name);
                System.IO.Directory.CreateDirectory(System.IO.Path.GetDirectoryName(file));
                System.IO.File.WriteAllBytes(file, content);
            }
            // This synthetic package deliberately gives every file the same
            // fixture bytes. Keep its per-material hashes internally aligned
            // so the test reaches the separate on-disk tampering check.
            if (data["atlasLineage"] is Newtonsoft.Json.Linq.JObject lineages)
                foreach (var lineage in lineages.Properties())
                    foreach (var textureHashEntry in ((Newtonsoft.Json.Linq.JObject)lineage.Value["textureHashes"]).Properties())
                        textureHashEntry.Value = digest;
            object manifest = Parse(data);
            var method = Importer.GetMethod("ValidatePackageFiles");
            Assert.DoesNotThrow(() => method.Invoke(null, new object[] { manifest, temporary }));
            string texture = (string)data["materials"][0]["texture"];
            System.IO.File.AppendAllText(System.IO.Path.Combine(temporary, texture), "changed");
            Reject(() => method.Invoke(null, new object[] { manifest, temporary }));
        }
        finally
        {
            if (System.IO.Directory.Exists(temporary)) System.IO.Directory.Delete(temporary, true);
        }
    }

    [TestCase("bed_duplicates")]
    [TestCase("locked_count")]
    [TestCase("locked_duplicates")]
    [TestCase("collider_x")]
    [TestCase("footprint_x")]
    [TestCase("source_axes")]
    public void BedAndOriginalObjectProofCannotDrift(string mutation)
    {
        var data = Fixture();
        if (mutation == "bed_duplicates")
            data["bedSourceObjects"][49] = data["bedSourceObjects"][0].DeepClone();
        else if (mutation == "locked_count")
            ((Newtonsoft.Json.Linq.JArray)data["lockedOriginalObjects"]).RemoveAt(149);
        else if (mutation == "locked_duplicates")
            data["lockedOriginalObjects"][149] = data["lockedOriginalObjects"][0].DeepClone();
        else if (mutation == "collider_x") data["bedCollider"]["boundsUnity"][0] = 5.0;
        else if (mutation == "footprint_x") data["bedCollider"]["footprintUnity"][0] = 5.0;
        else data["bedCollider"]["boundsBlender"][0] = -7.0;
        Reject(() => Parse(data));
    }

    [Test]
    public void ActualBedGeometryMustAgreeWithTheMeasuredCollider()
    {
        var data = Fixture();
        object manifest = Parse(data);
        var raw = (Newtonsoft.Json.Linq.JArray)data["bedCollider"]["boundsUnity"];
        var min = new Vector3((float)raw[0], (float)raw[1], (float)raw[2]);
        var max = new Vector3((float)raw[3], (float)raw[4], (float)raw[5]);
        var geometry = new Bounds((min + max) * .5f, max - min);
        var method = Importer.GetMethod("ValidateBedGeometry");
        Assert.DoesNotThrow(() => method.Invoke(null, new object[] { manifest, geometry }));
        geometry.center += new Vector3(.1f, 0, 0);
        Reject(() => method.Invoke(null, new object[] { manifest, geometry }));
    }

    [Test]
    public void ClosedDoorPoseIncludesRotationRelativeToItsModel()
    {
        var root = new GameObject("V4PoseTest");
        try
        {
            root.transform.rotation = Quaternion.Euler(0, 37, 0);
            var pivot = new GameObject("V4_EntryHinge");
            pivot.transform.SetParent(root.transform, false);
            pivot.transform.localPosition = new Vector3(2.985f, 0, 4.035f);
            var args = new object[] { root.transform, pivot.transform,
                new[] {2.985f, 0, 4.035f}, new[] {0f, 0, 0} };
            var method = Importer.GetMethod("ValidateDoorPose");
            Assert.DoesNotThrow(() => method.Invoke(null, args));
            pivot.transform.localRotation = Quaternion.Euler(0, 20, 0);
            Reject(() => method.Invoke(null, args));
            pivot.transform.localRotation = Quaternion.identity;
            pivot.transform.localPosition += new Vector3(.03f, 0, 0);
            Reject(() => method.Invoke(null, args));
        }
        finally { UnityEngine.Object.DestroyImmediate(root); }
    }
}
