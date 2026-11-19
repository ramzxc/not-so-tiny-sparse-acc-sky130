// Full FP8 model: egru/sim gate order and state equations, chip hard activations.
// Arithmetic tables come from the independent exact-rational E4M3FN oracle.
#include <algorithm>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <vector>
using Byte=uint8_t;
template<class T> std::vector<T> load(const std::filesystem::path& p) {
    std::ifstream f(p,std::ios::binary|std::ios::ate);
    if(!f) throw std::runtime_error(p.string());
    auto size=f.tellg(); std::vector<T> v(size/sizeof(T));
    f.seekg(0); f.read(reinterpret_cast<char*>(v.data()),size); return v;
}
int main(int argc,char** argv) {
    if(argc!=4)return 2;
    std::filesystem::path data(argv[1]), tables(argv[2]), out(argv[3]);
    std::filesystem::create_directories(out);
    auto a=load<Byte>(tables/"add.bin"),m=load<Byte>(tables/"mul.bin");
    auto sig=load<Byte>(tables/"sigmoid.bin"),tanh=load<Byte>(tables/"tanh.bin");
    auto value=load<float>(tables/"values.bin");
    auto w=load<Byte>(data/"kernel.bin"),r=load<Byte>(data/"recurrent_kernel.bin");
    auto bias=load<Byte>(data/"bias.bin"),rb=load<Byte>(data/"recurrent_bias.bin");
    auto threshold=load<Byte>(data/"threshold.bin"),hw=load<Byte>(data/"head_weight.bin"),hb=load<Byte>(data/"head_bias.bin");
    auto x=load<Byte>(data/"inputs.bin");auto offsets=load<uint64_t>(out/"offsets.bin");
    int h=threshold.size(),d=w.size()/(3*h),steps=x.size()/d;
    auto add=[&](Byte x,Byte y){return a[(int(x)<<8)|y];};
    auto mul=[&](Byte x,Byte y){return m[(int(x)<<8)|y];};
    auto sub=[&](Byte x,Byte y){return add(x,y^128);};
    std::vector<Byte> c(h,0),y(h,0),next(h),g(3*h),b(3*h);
    for(int i=0;i<3*h;++i)b[i]=add(bias[i],rb[i]);
    std::ofstream cy(out/"c.bin",std::ios::binary),yy(out/"y.bin",std::ios::binary),head(out/"head.bin",std::ios::binary);
    std::ofstream stats(out/"activity.csv");stats<<"step,input,previous,output\n";
    size_t trial=0;
    for(int t=0;t<steps;++t) {
        if(trial<offsets.size() && t==int(offsets[trial])) {std::fill(c.begin(),c.end(),0);std::fill(y.begin(),y.end(),0);++trial;}
        g=b;int ax=0,ay=0,an=0;
        for(int j=0;j<d;++j)if(x[t*d+j]&127) {
            ++ax;for(int i=0;i<2*h;++i)g[i]=add(g[i],mul(x[t*d+j],w[j*3*h+i]));
        }
        for(int j=0;j<h;++j)if(y[j]&127) {
            ++ay;for(int i=0;i<3*h;++i)g[i]=add(g[i],mul(y[j],r[j*3*h+i]));
        }
        for(int i=0;i<h;++i) {g[i]=sig[g[i]];g[h+i]=sig[g[h+i]];g[2*h+i]=mul(g[h+i],g[2*h+i]);}
        for(int j=0;j<d;++j)if(x[t*d+j]&127)
            for(int i=0;i<h;++i)g[2*h+i]=add(g[2*h+i],mul(x[t*d+j],w[j*3*h+2*h+i]));
        for(int i=0;i<h;++i) {
            Byte z=tanh[g[2*h+i]];
            Byte membrane=add(mul(sub(0x38,g[i]),z),mul(g[i],c[i]));
            bool event=value[membrane]>value[threshold[i]];
            next[i]=event?membrane:0;c[i]=event?sub(membrane,threshold[i]):membrane;
            an+=(next[i]&127)!=0;
        }
        y=next;Byte result[2]={hb[0],hb[1]};
        for(int i=0;i<h;++i)if(y[i]&127)
            for(int lane=0;lane<2;++lane)result[lane]=add(result[lane],mul(y[i],hw[2*i+lane]));
        cy.write(reinterpret_cast<char*>(c.data()),h);yy.write(reinterpret_cast<char*>(y.data()),h);
        head.write(reinterpret_cast<char*>(result),2);stats<<t<<','<<ax<<','<<ay<<','<<an<<'\n';
    }
    std::cout<<out<<": "<<steps<<" complete FP8 EGRU+FC steps\n";
}
