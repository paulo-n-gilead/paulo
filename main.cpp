#include <iostream>
#include <string.h>
int main(int argc, char** argv){
    if(argc>1 && strcmp(argv[1], "version") == 0){
        std::cout << "1.0\n";
        return 0;
    }
    std::cout << "Hello, from paulo!\n";
    return 0;
}
