Shader "_PathTracing/_Standard"
{
    Properties{
        _Color("Color", Color) = (1,1,1,1)
        _MainTex("Albedo", 2D) = "white" {}

        [Toggle]_Emission("Emission", Float) = 0
        [HDR]_EmissionColor("EmissionColor", Color) = (0,0,0)
        _EmissionTex("Emission", 2D) = "white" {}

        _SpecularColor("SpecularColor",Color) = (1,1,1,1)
        _Smoothness("Smoothness", Range(0.0 , 1.0)) = 0.5
        [Gamma] _Metallic("Metallic", Range(0.0 , 1.0)) = 0.0
        _IOR("Index of Refraction", Range(1.0, 2.8)) = 1.5
    }

    SubShader
    {
        Tags {"RenderType" = "Opaque" "DisableBatching" = "True"}
        LOD 100

        Pass{
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #include "UnityCG.cginc"

            #pragma shader_feature _EMISSION

            struct appdata
            {
                float4 vertex : POSITION;
                float3 normal : NORMAL;
                float2 uv : TEXCOORD0;
            };

            struct v2f
            {
                float2 uv0 : TEXCOORD0;
                #if _EMISSION
                float2 uv1 : TEXCOORD1;
                #endif
                float3 normal : NORMAL;
                float4 vertex : SV_POSITION;
            };

            sampler2D _MainTex;
            float4 _MainTex_ST;
            float4 _Color;

            sampler2D _EmissionTex;
            float4 _EmissionTex_ST;
            float4 _EmissionColor;

            v2f vert(appdata v)
            {
                v2f o;
                o.vertex = UnityObjectToClipPos(v.vertex);
                o.normal = UnityObjectToWorldNormal(v.normal);
                o.uv0 = TRANSFORM_TEX(v.uv, _MainTex);
                #if _EMISSION
                    o.uv1 = TRANSFORM_TEX(v.uv, _EmissionTex);
                #endif
                return o;
            }

            fixed4 frag(v2f i) : SV_Target
            {
                // 双边打光模型：仅为了在Scene视图下能更好的预览模型效果
                fixed4 col = tex2D(_MainTex, i.uv0) * _Color 
                            * saturate(saturate(dot(float3(-0.4, -1, -0.5), i.normal)) + saturate(dot(float3(0.4, 1, 0.5), i.normal)));
                #if _EMISSION
                    col += tex2D(_EmissionTex, i.uv1) * _EmissionColor;
                #endif
                return col;
            }
            ENDCG
        }
    }

    SubShader
    {
        Pass
        {
            Name "PathTracing"
            // DXR光线追踪模式专用的Shader Pass
            Tags{ "LightMode" = "PathTracing" }

            HLSLPROGRAM
            #include "UnityRaytracingMeshUtils.cginc"
            #include "_RayPayload.hlsl"
            #include "_Utils.hlsl"
            #include "_GlobalResources.hlsl"

            #pragma raytracing ClosestHitShader
            // 动态启用 _EMISSION 功能
            #pragma shader_feature_raytracing _EMISSION

            float4 _Color;
            Texture2D<float4> _MainTex;         // 主漫反射纹理
            float4 _MainTex_ST;
            SamplerState sampler__MainTex;

            float4 _EmissionColor;
            Texture2D<float4> _EmissionTex;
            float4 _EmissionTex_ST;
            SamplerState sampler__EmissionTex;
            
            float4 _SpecularColor;
            float _Smoothness;  // 表面光滑度
            float _Metallic;    // 金属度
            float _IOR;         // Index of Refraction

            // 用于接收当前命中的三角形片元的插值信息
            struct AttributeData{
                float2 barycentrics;
            };

            struct Vertex{
                float3 position;
                float3 normal;
                float2 uv;
            };

            Vertex FetchVertex(uint vertexIndex){
                Vertex v;
                // 从 Unity 提供的 Vertex Attribute 结构中读取数据
                v.position = UnityRayTracingFetchVertexAttribute3(vertexIndex, kVertexAttributePosition);
                v.normal = UnityRayTracingFetchVertexAttribute3(vertexIndex, kVertexAttributeNormal);
                v.uv = UnityRayTracingFetchVertexAttribute2(vertexIndex, kVertexAttributeTexCoord0);
                return v;
            }

            // 手动插值顶点属性
            Vertex InterpolateVertices(Vertex v0, Vertex v1, Vertex v2, float3 barycentrics){
                Vertex v;
                #define INTERPOLATE_ATTRIBUTE(attr) v.attr = v0.attr * barycentrics.x + v1.attr * barycentrics.y + v2.attr * barycentrics.z
                INTERPOLATE_ATTRIBUTE(position);
                INTERPOLATE_ATTRIBUTE(normal);
                INTERPOLATE_ATTRIBUTE(uv);
                return v;
            }

            [shader("closesthit")]
            void ClosestHitShader(inout RayPayload payload : SV_RayPayload, AttributeData attribs : SV_IntersectionAttributes){
            // 【判断反弹是否终止】
                if(payload.bounceIndexOpaque == g_BounceCountOpaque){
                    payload.bounceIndexOpaque = -1;
                    return;
                }
                
            // 【计算当前命中点的顶点属性】
                // 获取命中的三角面三个顶点索引
                uint3 triangleIndices = UnityRayTracingFetchTriangleIndices(PrimitiveIndex());
                Vertex v0 = FetchVertex(triangleIndices.x);
                Vertex v1 = FetchVertex(triangleIndices.y);
                Vertex v2 = FetchVertex(triangleIndices.z);
                // 当前点的重心坐标
                float3 barycentricCoords = float3(1.0 - attribs.barycentrics.x - attribs.barycentrics.y, attribs.barycentrics.x, attribs.barycentrics.y);
                // 插值当前点的顶点属性
                Vertex v = InterpolateVertices(v0, v1, v2, barycentricCoords);

            // 【计算当前点的法线】
                // 判断是否击中正面
                bool isFrontFace = HitKind() == HIT_KIND_TRIANGLE_FRONT_FACE;
                // 计算法线，如果背面击中，要翻转法线
                float3 localNormal = isFrontFace ? v.normal : -v.normal;
                float3 worldNormal = normalize(mul(localNormal, (float3x3)WorldToObject()));
                
            // 【反射方向】
                // 镜面反射比率（根据菲涅尔）
                float fresnelFactor = FresnelReflectAmountOpaque(isFrontFace ? 1 : _IOR, isFrontFace ? _IOR : 1, WorldRayDirection(), worldNormal);         
                float specularChance = lerp(_Metallic, 1, fresnelFactor * _Smoothness);
                // 随机决定当前反弹是specular还是diffuse
                float doSpecular = (RandomFloat01(payload.rngState) < specularChance) ? 1:0;
                // 漫反射方向采样
                float3 diffuseRayDir = normalize(worldNormal + RandomUnitVector(payload.rngState));
                // 镜面反射方向计算
                float3 specularRayDir = reflect(WorldRayDirection(), worldNormal);
                specularRayDir = normalize(lerp(diffuseRayDir, specularRayDir, _Smoothness));
                // 实际反射方向
                float3 reflectedRayDir = lerp(diffuseRayDir, specularRayDir, doSpecular);
            
            // 【计算新的起点】
                // 世界空间命中点位置
                float3 worldPosition = mul(ObjectToWorld(), float4(v.position, 1)).xyz;
                // 计算三角形几何法线
                float3 e0 = v1.position - v0.position;
                float3 e1 = v2.position - v0.position;
                float3 worldFaceNormal = normalize(mul(cross(e0,e1), (float3x3)WorldToObject()));

            // 【自发光】
                float3 emission = float3(0, 0, 0);
                #if _EMISSION
                    emission = _EmissionColor.xyz * _EmissionTex.SampleLevel(sampler__EmissionTex, _EmissionTex_ST.xy * v.uv + _EmissionTex_ST.zw, 0).xyz;
                #endif  

            // 【最终表面颜色】
                float3 albedo = _Color.xyz * _MainTex.SampleLevel(sampler__MainTex, _MainTex_ST.xy * v.uv + _MainTex_ST.zw, 0).xyz;

            // 【写入光线负载信息】
                payload.k                   = (doSpecular == 1) ? specularChance : 1 - specularChance;
                payload.albedo              = lerp(albedo, _SpecularColor.xyz, doSpecular);
                payload.emission            = emission;
                payload.bounceIndexOpaque   = payload.bounceIndexOpaque + 1;
                payload.bounceRayOrigin     = worldPosition + K_RAY_ORIGIN_PUSH_OFF * worldFaceNormal; //做了偏移，防止自交
                payload.bounceRayDirection  = reflectedRayDir;
            }
            ENDHLSL
        }
    }
    CustomEditor "PathTracingSimpleShaderGUI"
}