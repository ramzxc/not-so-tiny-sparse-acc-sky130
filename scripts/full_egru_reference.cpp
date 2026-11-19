// Reuse egru/sim's actual EGRU implementation; append a defined FP16 FC head.
#include "lib/model/egru.hpp"
#include <fstream>
#include <filesystem>
#include <iostream>
#include <vector>

template<class T> std::vector<T> read(const std::filesystem::path& path) {
    std::ifstream f(path, std::ios::binary | std::ios::ate);
    if (!f) throw std::runtime_error("cannot read " + path.string());
    auto bytes = f.tellg();
    std::vector<T> result(static_cast<size_t>(bytes)/sizeof(T));
    f.seekg(0); f.read(reinterpret_cast<char*>(result.data()), bytes);
    return result;
}

int main(int argc, char** argv) {
    if (argc != 3) return 2;
    const std::filesystem::path dir(argv[1]), out(argv[2]);
    std::filesystem::create_directories(out);
    auto bu=read<fp16>(dir/"b_u.bin"), br=read<fp16>(dir/"b_r.bin"), bz=read<fp16>(dir/"b_z.bin");
    auto wu=read<fp16>(dir/"W_u.bin"), wr=read<fp16>(dir/"W_r.bin"), wz=read<fp16>(dir/"W_z.bin");
    auto uu=read<fp16>(dir/"U_u.bin"), ur=read<fp16>(dir/"U_r.bin"), uz=read<fp16>(dir/"U_z.bin");
    auto thr=read<fp16>(dir/"thr.bin"), x=read<fp16>(dir/"inputs.bin");
    auto hw=read<fp16>(dir/"head_weight.bin"), hb=read<fp16>(dir/"head_bias.bin");
    auto offsets=read<uint64_t>(dir/"offsets.bin");
    int h=bu.size(), d=wu.size()/h, steps=x.size()/d;
    EGRU model(d,h);
    model.load_weights(wu.data(),uu.data(),wr.data(),ur.data(),wz.data(),uz.data());
    model.load_bias(bu.data(),br.data(),bz.data()); model.load_thr(thr.data());
    std::ofstream ys(out/"y.bin",std::ios::binary), cs(out/"c.bin",std::ios::binary);
    std::ofstream heads(out/"head.bin",std::ios::binary), counts(out/"counts.csv");
    counts << "step,active_input,active_previous,active_output\n";
    size_t trial=0;
    for (int t=0;t<steps;++t) {
        if (trial<offsets.size() && t==static_cast<int>(offsets[trial])) { model.reset(); ++trial; }
        int ax=0, previous=0, current=0;
        for (int i=0;i<d;++i) ax += x[t*d+i]!=fp16(0);
        for (int i=0;i<h;++i) previous += model.get_state()[i]!=fp16(0);
        VectorXhalf input=Eigen::Map<const VectorXhalf>(x.data()+t*d,d);
        const auto& y=model.step(input);
        fp16 head[2]={hb[0],hb[1]};
        for (int i=0;i<h;++i) {
            if (y[i]==fp16(0)) continue;
            ++current;
            for (int j=0;j<2;++j) head[j]=fp16(head[j]+fp16(y[i]*hw[2*i+j]));
        }
        ys.write(reinterpret_cast<const char*>(y.data()),h*2);
        cs.write(reinterpret_cast<const char*>(model.c_next_.data()),h*2);
        heads.write(reinterpret_cast<const char*>(head),4);
        counts << t << ',' << ax << ',' << previous << ',' << current << '\n';
    }
    std::cout << out << " " << steps << " complete EGRU+FC steps\n";
}
