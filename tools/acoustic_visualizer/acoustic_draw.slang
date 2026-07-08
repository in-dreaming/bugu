StructuredBuffer<float4> gVertices;

struct VSOutput
{
    float4 position : SV_Position;
    float4 color : COLOR0;
};

[shader("vertex")]
VSOutput vertexMain(uint vertexID : SV_VertexID)
{
    VSOutput output;
    output.position = gVertices[vertexID * 2u + 0u];
    output.color = gVertices[vertexID * 2u + 1u];
    return output;
}

[shader("fragment")]
float4 fragmentMain(VSOutput input) : SV_Target
{
    return input.color;
}
