cmake_minimum_required(VERSION 3.10)
project(paulo 
    VERSION 1.0.1
    DESCRIPTION "Paulo's Project"
    LANGUAGES CXX
)
add_executable(paulo main.cpp) 
install(TARGETS paulo DESTINATION bin)
