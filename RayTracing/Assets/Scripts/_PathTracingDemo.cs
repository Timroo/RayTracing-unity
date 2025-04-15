using System.Collections;
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.Experimental.Rendering;
using UnityEngine.Rendering;

[ExecuteInEditMode]
public class _PathTracingDemo : MonoBehaviour
{
    // Unity raytracing文件
    public RayTracingShader rayTracingShader = null;   
    
    public Cubemap envTexture = null;           // 环境贴图

    [Range(1, 100)]
    public uint bounceCountOpaque = 5;          // 不透明材质最大反射次数
    [Range(1, 100)]
    public uint bounceCountTransparent = 8;     // 透明材质最大反射次数

    // GPU 上的输出帧缓存，用于接收光追渲染结果
    private RayTracingAccelerationStructure rayTracingAccelerationStructure = null;

    private uint cameraWidth = 0;
    private uint cameraHeight = 0;
    private int convergenceStep = 0;
    private Matrix4x4 prevCameraMatrix;
    private uint prevBounceCountOpaque = 0;
    private uint prevBounceCountTransparent = 0;
    private RenderTexture rayTracingOutput = null;


    // 初始化 光追加速结构
    private void CreateRayTracingAccelerationStructure()
    {
        if(rayTracingAccelerationStructure == null){
            // 设置一个 光追加速结构 的 结构体
            RayTracingAccelerationStructure.RASSettings settings = new RayTracingAccelerationStructure.RASSettings();
            // 参与光追的对象类型：StaticOnly，DynamicOnly，Manual，EveryThing
            settings.rayTracingModeMask = RayTracingAccelerationStructure.RayTracingModeMask.Everything;
            // 加速结构管理模式：Automatic，Manual
            // - Automatic：自动将符合条件的场景物体添加进结构
            settings.managementMode = RayTracingAccelerationStructure.ManagementMode.Automatic;
            // 构建加速结构的 Layer 掩码（Layer Mask）
            // - 255 代表 Layer0~7 全部启用
            // - settings.layerMask = 1 << LayerMask.NameToLayer("RayTracing");
            settings.layerMask = 255;   // 默认添加所有物体

            rayTracingAccelerationStructure = new RayTracingAccelerationStructure(settings);
        }
    }

    // 资源创建
    private void CreateResources()
    {
        // 01 创建 光追加速结构
        CreateRayTracingAccelerationStructure();
        
        // 02 创建输出帧缓存，匹配相机分辨率（根据分辨率动态变化）
        if(cameraWidth != Camera.main.pixelWidth || cameraHeight != Camera.main.pixelHeight){
            if(rayTracingOutput)
                rayTracingOutput.Release();
                
            RenderTextureDescriptor rtDesc = new RenderTextureDescriptor()
            {
                dimension = TextureDimension.Tex2D,
                width = Camera.main.pixelWidth,
                height = Camera.main.pixelHeight,
                depthBufferBits = 0,
                volumeDepth = 1,
                msaaSamples = 1,
                vrUsage = VRTextureUsage.OneEye,
                graphicsFormat = GraphicsFormat.R32G32B32A32_SFloat,
                enableRandomWrite = true,
            };

            rayTracingOutput = new RenderTexture(rtDesc);
            rayTracingOutput.Create();

            cameraWidth = (uint)Camera.main.pixelWidth;
            cameraHeight = (uint)Camera.main.pixelHeight;

            convergenceStep = 0;
        }
    }

    // 资源释放
    // 销毁贴图和加速结构，避免内存泄漏
    private void ReleaseResources()
    {
        if(rayTracingAccelerationStructure != null){
            rayTracingAccelerationStructure.Release();
            rayTracingAccelerationStructure = null;
        }

        if(rayTracingOutput != null){
            rayTracingOutput.Release();
            rayTracingOutput = null;
        }

        cameraWidth = 0;
        cameraHeight = 0;
    }

    

    void OnDestroy()
    {
        ReleaseResources();
    }

    void OnDisable()
    {
        ReleaseResources();
    }

    private void OnEnable()
    {
        prevCameraMatrix = Camera.main.cameraToWorldMatrix;
        prevBounceCountOpaque = bounceCountOpaque;   
        prevBounceCountTransparent = bounceCountTransparent;
    }

    private void Update()
    {
        CreateResources();

        if(Input.GetKeyDown("space"))
            convergenceStep = 0;
    }

    [ImageEffectOpaque]
    void OnRenderImage(RenderTexture src, RenderTexture dest)
    {
        // 检查设备支持
        if(!SystemInfo.supportsRayTracing || !rayTracingShader){
            Debug.Log("The RayTracing API is not supported by this GPU or by the current graphics API.");
            Graphics.Blit(src, dest);
            return;
        }

        if (rayTracingAccelerationStructure == null)
            return;
        
        if (prevCameraMatrix != Camera.main.cameraToWorldMatrix)
            convergenceStep = 0;
        
        if (prevBounceCountOpaque != bounceCountOpaque)
            convergenceStep = 0;
        
        if (prevBounceCountTransparent != bounceCountTransparent)
            convergenceStep = 0;
        
        // 构建TLAS
        rayTracingAccelerationStructure.Build();

        rayTracingShader.SetShaderPass("PathTracing");

        // 输入
        Shader.SetGlobalInt(Shader.PropertyToID("g_BounceCountOpaque"), (int)bounceCountOpaque);
        Shader.SetGlobalInt(Shader.PropertyToID("g_BounceCountTransparent"), (int)bounceCountTransparent);

        rayTracingShader.SetAccelerationStructure(Shader.PropertyToID("g_AccelStruct"), rayTracingAccelerationStructure);
        rayTracingShader.SetFloat(Shader.PropertyToID("g_Zoom"), Mathf.Tan(Mathf.Deg2Rad * Camera.main.fieldOfView * 0.5f));
        rayTracingShader.SetFloat(Shader.PropertyToID("g_AspectRatio"), cameraWidth / (float)cameraHeight);
        rayTracingShader.SetInt(Shader.PropertyToID("g_ConvergenceStep"), convergenceStep);
        rayTracingShader.SetInt(Shader.PropertyToID("g_FrameIndex"), Time.frameCount);
        rayTracingShader.SetTexture(Shader.PropertyToID("g_EnvTex"), envTexture);

        // 输出
        rayTracingShader.SetTexture(Shader.PropertyToID("g_Radiance"), rayTracingOutput);

        // 执行光追 Dispatch
        // - MainRayGenShader 是 .raytrace 文件里主射线生成函数（RayGeneration）绑定的名称。
        // - (width, height, 1) 表示每个像素都发射一条主射线
        rayTracingShader.Dispatch("MainRayGenShader", (int)cameraWidth, (int)cameraHeight, 1, Camera.main);

        Graphics.Blit(rayTracingOutput, dest);

        // 收敛控制
        convergenceStep++;

        prevCameraMatrix            = Camera.main.cameraToWorldMatrix;
        prevBounceCountOpaque       = bounceCountOpaque;
        prevBounceCountTransparent  = bounceCountTransparent;

    }
}
