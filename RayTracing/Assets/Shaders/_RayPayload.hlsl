// 射线负载信息结构体
struct RayPayload
{
    float k;                        // 能量守恒因子：通常用于除以pdf（probability density function）
    float3 albedo;                  // 材质反射率
    float3 emission;                // 材质自发光
    uint bounceIndexOpaque;         // 不透明材质反弹次数
    uint bounceIndexTransparent;    // 透明材质反弹次数
    float3 bounceRayOrigin;         // 当前路径的下一个反弹点信息
    float3 bounceRayDirection;
    uint rngState;                  // 随机数种子
};