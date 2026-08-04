objects = main.o xovi.o
name = rmmirror-files-loopback

CXXFLAGS += -D_GNU_SOURCE -fPIC `pkg-config --cflags-only-I Qt6Core Qt6Network`

$(name).so: $(objects)
	$(CXX) $(CXXFLAGS) -shared -o $@ $(objects)

xovi.cpp xovi.h &: $(name).xovi
	python3 $(XOVI_REPO)/util/xovigen.py -o xovi.cpp -H xovi.h $(name).xovi

main.o: xovi.h main.cpp

.PHONY: clean
clean:
	rm -f $(name).so $(objects) xovi.cpp xovi.h
