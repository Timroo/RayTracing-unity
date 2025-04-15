Shader "PathTracing/_StandardGlass"
{
    Properties
    {
        _Color ("Color", Color) = (1,1,1,1)
        // 消光系数:用于模拟透明介质（如玻璃、水）对光线吸收衰减的参数
        _ExtinctionCoefficient("Extinction Coefficient", Range(0.0, 20.0)) = 1.0

        _Roughness ("Roughness", Range(0.0, 0.5)) = 0.0

        [Toggle] _FlatShading("Flat Shading", Float) = 0

        _IOR("Index of Refraction", Range(0.0, 2.8)) = 1.5
    }

    SubShader
    {
        Tags { "RenderType"="Opaque" "DisableBatching"="True"}
        LOD 100

        Pass
        {
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #include "UnityCG.cginc"

            struct appdata
            {
                float4 vertex : POSITION;
                float3 normal : NORMAL;
            };

            struct v2f
            {
                float4 vertex : SV_POSITION;
                float3 normal : NORMAL;
            };

            float4 _Color;

            v2f vert(appdata v)
            {
                v2f o;
                o.vertex = UnityObjectToClipPos(v.vertex);
                o.normal = UnityObjectToWorldNormal(v.normal);       
                return o;
            }

            fixed4 frag(v2f i) : SV_Target
            {
                fixed4 col = _Color * saturate(saturate(dot(float3(-0.4, -1, -0.5), i.normal)) + saturate(dot(float3(0.4, 1, 0.5), i.normal)));
                return col;
            }
            ENDCG
        }
    }

    SubShader{
        Pass{
            Name "PathTracing"
            Tags{ "LightMode" = "RayTracing" }
            HLSLPROGRAM
   
            #include "UnityRaytracingMeshUtils.cginc"
            #include "_RayPayload.hlsl"
            #include "_Utils.hlsl"
            #include "_GlobalResources.hlsl"

            #pragma raytracing test

            // 是否使用平面着色
            #pragma shader_feature _ FLAT_SHADING

            float4 _Color;
            float _IOR;         //折射率（Index of Refraction）
            float _Roughness;
            float _ExtinctionCoefficient;
            float _FlatShading;

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
                v.position = UnityRayTracingFetchVertexAttribute3(vertexIndex, kVertexAttributePosition);
                v.normal = UnityRayTracingFetchVertexAttribute3(vertexIndex, kVertexAttributeNormal);
                v.uv = UnityRayTracingFetchVertexAttribute3(vertexIndex, kVertexAttributeTexCoord0);
                return v;
            }

            Vertex InterpolateVertices(Vertex v0, Vertex v1, Vertex v2, float3 barycentrics){
                Vertex v;
                #define INTERPOLATE_ATTRIBUTE(attr) v.attr = v0.attr * barycentrics.x + v1.attr * barycentrics.y + v2.attr * barycentrics.z
                INTERPOLATE_ATTRIBUTE(position);
                INTERPOLATE_ATTRIBUTE(normal);
                INTERPOLATE_ATTRIBUTE(uv);
                return v;
            }
            
            [shader("closesthit")]
            void ClosestHitMain(inout RayPayload payload : SV_RayPayload, AttributeData attribs : SV_IntersectionAttributes){
            // 【弹射终止判断】
                if(payload.bounceIndexTransparent == g_BounceCountTransparent){
                    payload.bounceIndexTransparent = -1;
                    return;
                }

            // 【插值命中点属性】
                uint3 triangleIndices = UnityRayTracingFetchTriangleIndices(PrimitiveIndex());
                Vertex v0, v1, v2;
                v0 = FetchVertex(triangleIndices.x);
                v1 = FetchVertex(triangleIndices.y);
                v2 = FetchVertex(triangleIndices.z);
                float3 barycentricCoords = float3(1.0 - attribs.barycentrics.x - attribs.barycentrics.y, attribs.barycentrics.x, attribs.barycentrics.y);
                Vertex v = InterpolateVertices(v0, v1, v2, barycentricCoords);

            // 【命中面法线方向（世界空间）】
                // 是否使用 平面着色
                #if _FLAT_SHADING   
                    float3 e0 = v1.position - v0.position;
                    float3 e1 = v2.position - v0.position;
                    float3 localNormal = normalize(cross(e0, e1));
                #else
                    float3 localNormal = v.normal;
                #endif
                // 根据正反面进行调整
                bool isFrontFace = HitKind() == HIT_KIND_TRIANGLE_FRONT_FACE; 
                float normalSign = isFrontFace ? 1.0 : -1.0;
                localNormal *= normalSign;
                // 使用roughness模拟微表面（磨砂）
                float3 roughness = _Roughness * RandomUnitVector(payload.rngState);
                float3 worldNormal = normalize(mul(localNormal, (float3x3)WorldToObject()) + roughness);

            // 【确定反弹方向（反射or折射）】
                // 先计算 反射方向 & 折射方向
                float3 reflectionRayDir = reflect(WorldRayDirection(), worldNormal); // 反射方向
                float indexOfRefraction = isFrontFace ? 1.0 / _IOR : _IOR;
                float3 refractionRayDir = refract(WorldRayDirection(), worldNormal, indexOfRefraction);// 折射方向
                // 根据菲涅尔 最终确定
                float fresnelFactor = FresnelReflectAmountTransparent(isFrontFace ? 1: _IOR, isFrontFace ? _IOR : 1, WorldRayDirection(), worldNormal);
                float doRefraction = (RandomFloat01(payload.rngState) > fresnelFactor) ? 1:0 ;
                float3 bounceRayDir = lerp(reflectionRayDir, refractionRayDir, doRefraction);
            
            // 【计算新的起点】
                float3 worldPosition = mul(ObjectToWorld(), float4(v.position, 1)).xyz;
                // 根据反射or折射 确定偏移方向
                float pushOff = doRefraction ? -K_RAY_ORIGIN_PUSH_OFF : K_RAY_ORIGIN_PUSH_OFF;

            // 【最终颜色】
                float3 albedo = !isFrontFace ? exp(-(1 - _Color.xyz) * RayTCurrent() * _ExtinctionCoefficient) : float3(1,1,1);

            // 【写入光线负载信息payload】
                payload.k = (doRefraction == 1) ? 1 - fresnelFactor : fresnelFactor;
                payload.albedo = albedo;
                payload.emission = float3(0,0,0);
                payload.bounceIndexTransparent = payload.bounceIndexTransparent + 1;
                payload.bounceRayOrigin = worldPosition + pushOff * worldNormal;
                payload.bounceRayDirection = bounceRayDir;
            }

            ENDHLSL
        }
    }
    CustomEditor "PathTracingSimpleGlassShaderGUI"
}
