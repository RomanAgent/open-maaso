using System;
using System.Collections.Generic;
using System.Linq;
using NUnit.Framework;
using UnityEditor;
using UnityEngine;
using UnityEngine.Rendering;
using Object=UnityEngine.Object;

public sealed class CoastalWindowAtmosphereTests
{
    private static Type Builder => Type.GetType("Maaso.World.Editor.CoastalCloudMeshBuilder, Assembly-CSharp-Editor",true);
    private static Type Atmosphere => Type.GetType("Maaso.World.CoastalWindowAtmosphere, Assembly-CSharp",true);

    [Test] public void ReviewedOceanOverscanUsesClampRatherThanRepeatingTheCoast()
    {
        const string path="Assets/MaasoWorld/PersonalSpace/CoastalV4/Textures/Baked_Ocean.png";
        var texture=AssetDatabase.LoadAssetAtPath<Texture2D>(path);
        Assert.That(texture,Is.Not.Null);
        Assert.That(texture.wrapModeU,Is.EqualTo(TextureWrapMode.Clamp));
        Assert.That(texture.wrapModeV,Is.EqualTo(TextureWrapMode.Clamp));
    }

    [Test] public void PublishedBackdropReplacesOverscannedPlaneAndCoversNearWindowRays()
    {
        var room=Resources.Load<GameObject>("PersonalSpaceModel");
        var source=room.GetComponentsInChildren<MeshRenderer>(true).Single(r=>r.name=="V2_Distant_Ocean");
        Assert.That(source.enabled,Is.False,"Legacy photograph plane must not overlap the new backdrop.");
        var backdrop=room.GetComponentsInChildren<MeshRenderer>(true).Single(r=>r.name=="CoastalWindowBackdrop");
        var mesh=backdrop.GetComponent<MeshFilter>().sharedMesh;
        Assert.That(mesh.vertexCount,Is.LessThan(6000));
        Assert.That(mesh.uv.All(uv=>uv.x>=0 && uv.x<=1 && uv.y>=0 && uv.y<=1),Is.True);
        Assert.That(backdrop.sharedMaterial,Is.SameAs(source.sharedMaterial));
        Assert.That(backdrop.GetComponent<Collider>(),Is.Null);
        // Cast real camera rays against the published mesh. The fixture collider
        // exists only in this test, never in the shipped scene.
        var fixture=new GameObject("backdrop-ray-fixture");
        try
        {
            var collider=fixture.AddComponent<MeshCollider>();collider.sharedMesh=mesh;
            Physics.SyncTransforms();
            foreach(float x in new[]{-2.5f,0f,2.5f})
            foreach(float z in new[]{-1.8f,-3.9f})
            foreach(float yaw in new[]{-85f,-60f,0f,60f,85f})
            foreach(float pitch in new[]{-75f,-40f,0f,40f,75f})
            {
                var direction=Quaternion.Euler(pitch,yaw,0)*Vector3.back;
                var ray=new Ray(new Vector3(x,1.65f,z),direction);
                Assert.That(collider.Raycast(ray,out var hit,65f),Is.True,$"Background gap: {x},{z} yaw={yaw} pitch={pitch}");
                Assert.That(hit.textureCoord.x,Is.InRange(.005f,.995f));
                Assert.That(hit.textureCoord.y,Is.InRange(.005f,.995f));
            }
        }
        finally { Object.DestroyImmediate(fixture); }
    }

    [Test] public void CloudProxyEnclosesTheDensityDomainWithTwelveOutwardTriangles()
    {
        var mesh=(Mesh)Builder.GetMethod("BuildMesh").Invoke(null,null);
        try
        {
            Assert.That(mesh.vertexCount,Is.EqualTo(8));
            Assert.That(mesh.bounds.center,Is.EqualTo(Vector3.zero));
            Assert.That(mesh.bounds.size,Is.EqualTo(Vector3.one));
            var vertices=mesh.vertices;var triangles=mesh.triangles;
            Assert.That(triangles.Length,Is.EqualTo(36));
            var edges=new Dictionary<ulong,int>();
            void Edge(int a,int b)
            {if(a>b)(a,b)=(b,a);ulong key=((ulong)(uint)a<<32)|(uint)b;edges[key]=edges.TryGetValue(key,out int n)?n+1:1;}
            for(int i=0;i<triangles.Length;i+=3)
            {
                int a=triangles[i],b=triangles[i+1],c=triangles[i+2];
                var outward=(vertices[a]+vertices[b]+vertices[c])/3f;
                Assert.That(Vector3.Dot(Vector3.Cross(vertices[b]-vertices[a],vertices[c]-vertices[a]),outward),Is.GreaterThan(0f),
                    "The volume proxy must have consistent outward winding for single-sided ray integration.");
                Edge(a,b);Edge(b,c);Edge(c,a);
            }
            Assert.That(edges.Values.All(count=>count==2),Is.True,"The volume proxy must be closed.");
        }
        finally{Object.DestroyImmediate(mesh);}
    }

    [Test] public void DensityBakeHasSoftThreeDimensionalCloudsAndNoAtlasEdgeLeakage()
    {
        var texture=(Texture3D)Builder.GetMethod("BuildDensityTexture").Invoke(null,null);
        try
        {
            Assert.That(new Vector3Int(texture.width,texture.height,texture.depth),Is.EqualTo(new Vector3Int(256,96,80)));
            Assert.That(texture.format,Is.EqualTo(TextureFormat.RGBA32));
            Assert.That(texture.graphicsFormat,Is.EqualTo(UnityEngine.Experimental.Rendering.GraphicsFormat.R8G8B8A8_UNorm),
                "Density and precomputed light are linear data, never sRGB colors.");
            Assert.That(texture.mipmapCount,Is.EqualTo(1));
            Assert.That(texture.wrapMode,Is.EqualTo(TextureWrapMode.Clamp));
            Assert.That(texture.filterMode,Is.EqualTo(FilterMode.Bilinear));
            var pixels=texture.GetPixels32();
            const int variantWidth=128,padding=3;
            int differentVoxels=0;
            for(int variant=0;variant<2;variant++)
            {
                int occupied=0,soft=0,minLight=255,maxLight=0,minAmbient=255,maxAmbient=0,minHeight=255,maxHeight=0;
                var occupiedDepths=new HashSet<int>();
                for(int z=0;z<texture.depth;z++) for(int y=0;y<texture.height;y++) for(int x=0;x<variantWidth;x++)
                {
                    int index=(z*texture.height+y)*texture.width+x+variant*variantWidth;
                    Color32 voxel=pixels[index];
                    if(x<padding||x>=variantWidth-padding||y<padding||y>=texture.height-padding||z<padding||z>=texture.depth-padding)
                        Assert.That(voxel.r,Is.Zero,$"Variant {variant} density leaks through its padding at {x},{y},{z}.");
                    if(voxel.r>0)
                    {
                        occupied++;occupiedDepths.Add(z);
                        if(voxel.r<255)soft++;
                        minLight=Math.Min(minLight,voxel.g);maxLight=Math.Max(maxLight,voxel.g);
                        minAmbient=Math.Min(minAmbient,voxel.b);maxAmbient=Math.Max(maxAmbient,voxel.b);
                        minHeight=Math.Min(minHeight,voxel.a);maxHeight=Math.Max(maxHeight,voxel.a);
                    }
                    if(variant==0 && Math.Abs(voxel.r-pixels[index+variantWidth].r)>8)differentVoxels++;
                }
                Assert.That(occupied,Is.GreaterThan(1000),$"Variant {variant} must contain an actual volume.");
                Assert.That(soft,Is.GreaterThan(occupied/4),"A binary solid shell cannot provide soft extinction edges.");
                Assert.That(occupiedDepths.Count,Is.GreaterThan(texture.depth/3),"Cloud density must extend through depth, not lie on a card.");
                Assert.That(maxLight-minLight,Is.GreaterThan(20),"Baked sunlight must distinguish the exposed rim and self-shadowed interior.");
                Assert.That(maxAmbient-minAmbient,Is.GreaterThan(20),"Ambient occlusion must vary through the cloud volume.");
                Assert.That(maxHeight-minHeight,Is.GreaterThan(20));
            }
            Assert.That(differentVoxels,Is.GreaterThan(1000),"Both cloud variants must have distinct density silhouettes.");
        }
        finally{Object.DestroyImmediate(texture);}
    }

    [Test] public void PublishedCloudAssetsUseTheBoundedVolumeShaderAndSharedDensityTexture()
    {
        string Field(string name)=>(string)Builder.GetField(name).GetValue(null);
        var texture=AssetDatabase.LoadAssetAtPath<Texture3D>(Field("DensityPath"));
        var mesh=AssetDatabase.LoadAssetAtPath<Mesh>(Field("MeshPath"));
        var material=AssetDatabase.LoadAssetAtPath<Material>(Field("MaterialPath"));
        Assert.That(texture,Is.Not.Null,"Publish the updated cloud assets before testing the shipping prefab.");
        Assert.That(mesh,Is.Not.Null);
        Assert.That(material,Is.Not.Null);
        Assert.That(new Vector3Int(texture.width,texture.height,texture.depth),Is.EqualTo(new Vector3Int(256,96,80)));
        Assert.That(texture.width*texture.height*texture.depth*4,Is.LessThanOrEqualTo(8*1024*1024),
            "The two shared variants must remain inside the reviewed 8 MiB raw-texel budget.");
        Assert.That(texture.graphicsFormat,Is.EqualTo(UnityEngine.Experimental.Rendering.GraphicsFormat.R8G8B8A8_UNorm));
        Assert.That(texture.isReadable,Is.False,"Published density must release its runtime CPU pixel copy.");
        Assert.That(texture.mipmapCount,Is.EqualTo(1));
        Assert.That(texture.wrapModeU,Is.EqualTo(TextureWrapMode.Clamp));
        Assert.That(texture.wrapModeV,Is.EqualTo(TextureWrapMode.Clamp));
        Assert.That(texture.wrapModeW,Is.EqualTo(TextureWrapMode.Clamp));
        Assert.That(texture.filterMode,Is.EqualTo(FilterMode.Bilinear));
        Assert.That(material.GetTexture("_DensityVolume"),Is.SameAs(texture));
        Assert.That(material.GetFloat("_StepCount"),Is.InRange(1f,56f));
        Assert.That(material.GetFloat("_Extinction"),Is.GreaterThan(0f));
        Assert.That(material.GetTag("RenderType",false),Is.EqualTo("Transparent"));
        var shader=material.shader;
        Assert.That(shader.name,Is.EqualTo("Maaso/Coastal Cloud Volume"));
        Assert.That(ShaderUtil.ShaderHasError(shader),Is.False,
            string.Join("\n",ShaderUtil.GetShaderMessages(shader).Select(message=>message.message)));
        foreach(string resource in new[]{"PersonalSpaceModel","PersonalSpaceMap"})
        {
            var prefab=Resources.Load<GameObject>(resource);
            var component=prefab.GetComponentInChildren(Atmosphere,true);
            Assert.That(component,Is.Not.Null,resource);
            Assert.That(Atmosphere.GetProperty("CloudMesh").GetValue(component),Is.SameAs(mesh));
            Assert.That(Atmosphere.GetProperty("CloudMaterial").GetValue(component),Is.SameAs(material));
        }
    }

    [Test] public void DriftingCloudsStayOutsideAndReuseTheirMeshWithoutPhysicsOrShadows()
    {
        var root=new GameObject("atmosphere-test");
        var mesh=(Mesh)Builder.GetMethod("BuildMesh").Invoke(null,null);
        var material=new Material(Shader.Find("Maaso/Coastal Cloud Volume"));
        try
        {
            var component=root.AddComponent(Atmosphere);
            Atmosphere.GetMethod("Configure").Invoke(component,new object[]{mesh,material});
            Atmosphere.GetMethod("PresentAt").Invoke(component,new object[]{0f});
            var renderers=root.GetComponentsInChildren<MeshRenderer>();
            Assert.That(renderers.Length,Is.EqualTo(6));
            var before=renderers.Select(r=>r.transform.localPosition).ToArray();
            Atmosphere.GetMethod("PresentAt").Invoke(component,new object[]{16f});
            Assert.That(Vector3.Distance(before[0],renderers[0].transform.localPosition),Is.InRange(.05f,.2f),
                "Visible drift should be gentle over sixteen seconds.");
            for(int frame=0;frame<50;frame++)
            {
                Atmosphere.GetMethod("PresentAt").Invoke(component,new object[]{frame*300f});
                for(int i=0;i<renderers.Length;i++)
                {
                    var renderer=renderers[i];
                    var bounds=renderer.bounds;
                    Assert.That(Vector3.Distance(before[i],renderer.transform.localPosition),Is.LessThan(2f));
                    for(int j=i+1;j<renderers.Length;j++)
                        Assert.That(bounds.Intersects(renderers[j].bounds),Is.False,
                            $"Cloud proxies {i} and {j} overlap, making transparent object sorting ambiguous.");
                    foreach(int x in new[]{-1,1}) foreach(int y in new[]{-1,1}) foreach(int z in new[]{-1,1})
                    {
                        var corner=bounds.center+Vector3.Scale(bounds.extents,new Vector3(x,y,z));
                        Assert.That(Vector3.Distance(corner,new Vector3(0,1.5f,-4)),Is.LessThan(48f),
                            "Cloud must stay in front of the backdrop, without crossing its shell.");
                    }
                }
            }
            Assert.That(root.GetComponentsInChildren<MeshRenderer>().Length,Is.EqualTo(6));
            Assert.That(root.GetComponentsInChildren<Collider>().Length,Is.Zero);
            foreach(var renderer in renderers)
            {
                Assert.That(renderer.bounds.max.z,Is.LessThan(-12f));
                Assert.That(renderer.bounds.min.y,Is.GreaterThan(4f));
                Assert.That(renderer.sharedMaterial,Is.SameAs(material));
                Assert.That(renderer.GetComponent<MeshFilter>().sharedMesh,Is.SameAs(mesh));
                Assert.That(renderer.shadowCastingMode,Is.EqualTo(ShadowCastingMode.Off));
            }
            root.SetActive(false);
            // EditMode does not dispatch a runtime-only component's lifecycle.
            Atmosphere.GetMethod("OnDisable",System.Reflection.BindingFlags.Instance|System.Reflection.BindingFlags.NonPublic)
                .Invoke(component,null);
            Assert.That(root.transform.childCount,Is.Zero);
            Assert.That(mesh,Is.Not.Null,"Instance cleanup must not destroy the shared mesh asset.");
        }
        finally{Object.DestroyImmediate(root);Object.DestroyImmediate(material);Object.DestroyImmediate(mesh);}
    }
}
